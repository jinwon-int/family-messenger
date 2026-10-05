//! Memory-only synthetic qualification; no account trust or durable state.
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::RustCrypto;
use openmls_traits::storage::{StorageProvider, CURRENT_VERSION};
use tls_codec::{Deserialize as TlsDeserialize, Serialize};
use wasm_bindgen::prelude::*;

const SUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
/// Longest wire input/output (review M4-era bound). M5 (#177 §4): raised from
/// 64 KiB so the ciphertext of a full-size attachment crosses it in one MLS
/// application message — measured: 262144-byte plaintext = 262350-byte
/// ciphertext (see `attachment_256kib_rounds_trip`), so 256 KiB + 4 KiB of MLS
/// framing headroom. The relay's per-room 64 MiB cap stays the real bound.
/// Measured (`attachment_256kib_rounds_trip`): 262144-byte plaintext →
/// 262350-byte ciphertext.
const MAX_WIRE: usize = 262144 + 4096;
/// Longest encrypt plaintext (M5): an attachment up to 256 KiB rides as the
/// MLS application payload directly — no chunking layer.
pub const MAX_ATTACHMENT: usize = 262144;
/// Longest identity label (`valid_identity`); also the bound every length-prefixed
/// identity field is checked against *before* any offset arithmetic (review M3:
/// `4 + len` must not wrap on wasm32, where `usize` is 32 bits).
const MAX_IDENTITY: usize = 64;
/// Outstanding (unconsumed) KeyPackages one device may hold (review M4). Each
/// costs one store entry; without a cap a device that keeps publishing would
/// walk into the 512-entry `open` bound ("state limit") and lose the session.
pub(crate) const MAX_KEY_PACKAGES: usize = 8;
/// Review 2 J-HB (#231): keep the message secrets of a few past epochs so an
/// application message the relay ordered before a commit — or that a device
/// reads only after merging its own commit — still decrypts instead of being
/// tombstoned as poison. Bounded: three epochs of secret-tree state.
pub(crate) const PAST_EPOCHS: usize = 3;
/// `decrypt` output format (review H1): `u32 LE len ‖ sender_device ‖ u32 LE len ‖
/// client_id ‖ plaintext`. Bumped whenever the framing changes; JS callers assert it.
pub const DECRYPT_FORMAT: u32 = 2;
/// `stage_commit` report format (review 2 J-MB, #231): four concatenated
/// [`policy::frame_members`] sections — adds ‖ removes ‖ update proposals ‖
/// committer path leaf, each a sorted `(identity, signing key)` list. Bumped
/// whenever the framing changes; JS callers assert it
/// (`Device.stage_report_format`).
pub const STAGE_REPORT_FORMAT: u32 = 2;
/// Every facade error. It is converted to a `JsValue` only at the wasm-bindgen
/// boundary, so host-target unit tests can exercise rejection paths (creating a
/// `JsValue` outside wasm panics).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rejected(&'static str);
impl From<Rejected> for JsValue {
    fn from(error: Rejected) -> JsValue { JsValue::from_str(error.0) }
}
fn rejected<T>(_: T) -> Rejected { Rejected("MLS operation rejected") }
/// Identity labels are opaque application identifiers (`actor/device`), validated by
/// shape only. Trust never comes from the label; it comes from independently pinned keys.
fn valid_identity(identity: &str) -> bool {
    !identity.is_empty() && identity.len() <= MAX_IDENTITY
        && identity.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b))
}
fn bounded(bytes: &[u8], max: usize) -> Result<(), Rejected> {
    if bytes.is_empty() || bytes.len() > max { Err(Rejected("size rejected")) } else { Ok(()) }
}

/// §3.6 application-message binding (#177 B9): every application message
/// carries AAD = `room ‖ group_id ‖ sender_device ‖ client_id ‖ epoch`,
/// canonically framed as `u32 LE length ‖ bytes` per field plus a trailing
/// `u64 LE` epoch, so fields cannot shift into one another. The receiver
/// re-derives what it knows independently (its room, the group id, the
/// MLS-authenticated sender device, the wire epoch) and refuses any mismatch,
/// even though the AEAD itself would still open.
pub(crate) fn aad_bytes(room: &[u8], group_id: &[u8], sender_device: &[u8], client_id: &[u8], epoch: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(24 + room.len() + group_id.len() + sender_device.len() + client_id.len());
    for field in [room, group_id, sender_device, client_id] {
        out.extend_from_slice(&(field.len() as u32).to_le_bytes());
        out.extend_from_slice(field);
    }
    out.extend_from_slice(&epoch.to_le_bytes());
    out
}

pub(crate) struct Aad {
    pub room: Vec<u8>,
    pub group_id: Vec<u8>,
    pub sender_device: Vec<u8>,
    pub client_id: Vec<u8>,
    pub epoch: u64,
}

/// Strict inverse of `aad_bytes`: exact bounds (identities ≤ 64 bytes like
/// `valid_identity`, group id ≤ 64, non-empty), `valid_identity` text for
/// room/sender/client, no trailing bytes. `client_id` is returned so the
/// receiver can bind it to the MLS-authenticated sender (review H1) and hand
/// it on to the application as attribution.
pub(crate) fn parse_aad(bytes: &[u8]) -> Option<Aad> {
    fn field(rest: &mut &[u8], max: usize, identity: bool) -> Option<Vec<u8>> {
        if rest.len() < 4 { return None; }
        let len = u32::from_le_bytes(rest[..4].try_into().ok()?) as usize;
        // Bound first: `4 + len` is computed only for len ≤ max (≤ 64).
        if len > max || rest.len() - 4 < len { return None; }
        let (value, tail) = rest.split_at(4 + len);
        let value = &value[4..];
        *rest = tail;
        if identity { valid_identity(std::str::from_utf8(value).ok()?).then_some(())?; }
        Some(value.to_vec())
    }
    let mut rest = bytes;
    let room = field(&mut rest, MAX_IDENTITY, true)?;
    let group_id = field(&mut rest, 64, false)?;
    if group_id.is_empty() { return None; }
    let sender_device = field(&mut rest, MAX_IDENTITY, true)?;
    let client_id = field(&mut rest, MAX_IDENTITY, true)?;
    if rest.len() != 8 { return None; }
    let epoch = u64::from_le_bytes(rest.try_into().ok()?);
    Some(Aad { room, group_id, sender_device, client_id, epoch })
}

/// `u32 LE length ‖ identity ‖ rest` — the caller-declared part of the
/// encrypt/decrypt input (the room, then the client id for encrypt). The
/// caller declares these per message; trust stays with the MLS checks.
///
/// Review M3: the length is bounded by `MAX_IDENTITY` *before* any offset is
/// formed, and the offset uses `checked_add`, so a length such as `u32::MAX - 1`
/// or `0xFFFF_FFFC` can neither wrap on a 32-bit `usize` (wasm32) nor index out
/// of range on the host — both are simply rejected.
pub(crate) fn split_identity(bytes: &[u8]) -> Result<(&str, &[u8]), Rejected> {
    if bytes.len() < 4 { return Err(rejected(())); }
    let len = u32::from_le_bytes(bytes[..4].try_into().map_err(|_| rejected(()))?);
    if len == 0 || len as u64 > MAX_IDENTITY as u64 { return Err(rejected(())); }
    let len = len as usize;
    let end = 4usize.checked_add(len).ok_or_else(|| rejected(()))?;
    if end > bytes.len() { return Err(rejected(())); }
    let identity = std::str::from_utf8(&bytes[4..end]).map_err(|_| rejected(()))?;
    if !valid_identity(identity) { return Err(rejected(())); }
    Ok((identity, &bytes[end..]))
}

/// `decrypt` output (`DECRYPT_FORMAT` 2): `u32 LE len ‖ sender_device ‖ u32 LE
/// len ‖ client_id ‖ plaintext`. Both labels were authenticated before this is
/// built (sender by MLS, client by the AAD binding below), so a consumer may
/// display them as attribution without re-deriving anything.
pub(crate) fn frame_decrypt(sender_device: &[u8], client_id: &[u8], plaintext: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + sender_device.len() + client_id.len() + plaintext.len());
    for field in [sender_device, client_id] {
        out.extend_from_slice(&(field.len() as u32).to_le_bytes());
        out.extend_from_slice(field);
    }
    out.extend_from_slice(plaintext);
    out
}

/// MLS-authenticated application sender as this facade's devices see it: the
/// AAD-checked device identity, the AAD-bound client id, the roster credential
/// and leaf signing key.
pub(crate) struct AuthenticatedSender {
    pub device: Vec<u8>,
    pub client_id: Vec<u8>,
    pub credential: Credential,
    /// The sender's leaf signing key as of the current tree; `None` for a
    /// past-epoch message whose leaf a later commit removed (OpenMLS verified
    /// it against that epoch's leaves, but does not expose the key) — pinned
    /// lanes refuse such a message, the roster lane attributes it by the
    /// authenticated credential.
    pub signature_key: Option<Vec<u8>>,
}

/// Crypto from `openmls_rust_crypto`, storage from this crate's v2 [`store::Store`]
/// (#177 §3.5) — the only provider the facade uses.
#[derive(Default)]
pub(crate) struct Provider {
    crypto: RustCrypto,
    storage: store::Store,
}

impl Provider {
    pub(crate) fn with_store(storage: store::Store) -> Self { Self { crypto: RustCrypto::default(), storage } }
}

impl OpenMlsProvider for Provider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = store::Store;
    fn storage(&self) -> &Self::StorageProvider { &self.storage }
    fn crypto(&self) -> &Self::CryptoProvider { &self.crypto }
    fn rand(&self) -> &Self::RandProvider { &self.crypto }
}

/// One fresh disposable device, with a single in-memory group.
#[wasm_bindgen]
pub struct Device {
    provider: Provider,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
    group: Option<MlsGroup>,
    /// An incoming commit processed by `stage_commit` but not yet merged
    /// (review M1); memory only, dropped with the group on any rollback.
    staged: Option<StagedCommit>,
    retired: bool,
}

#[wasm_bindgen]
impl Device {
    #[wasm_bindgen(constructor)]
    pub fn new(identity: &str) -> Result<Device, Rejected> {
        Self::with_provider(identity, Provider::default())
    }
}

impl Device {
    /// A new identity whose signer is written into `provider`'s store.
    pub(crate) fn with_provider(identity: &str, provider: Provider) -> Result<Device, Rejected> {
        if !valid_identity(identity) { return Err(Rejected("identity rejected")); }
        let signer = SignatureKeyPair::new(SUITE.signature_algorithm()).map_err(rejected)?;
        signer.store(provider.storage()).map_err(rejected)?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity.as_bytes().to_vec()).into(),
            signature_key: signer.public().into(),
        };
        Ok(Self { provider, signer, credential, group: None, staged: None, retired: false })
    }

}

/// Host-only state persistence (the native MLS bot's persistent identity).
/// Deliberately NOT on the `#[wasm_bindgen]` surface: the worker snapshot API
/// was removed in #177 M2b-3c and the browser keeps holding its secrets inside
/// the worker. A native host that already holds the keys in process may move
/// them to a state file, so export/import live on a plain Rust `impl` the JS
/// bridge cannot see.
impl Device {
    /// Bounded JSON snapshot of the whole provider store plus the identity /
    /// public-key / group binding. The `identity` is baked into the bytes and
    /// re-checked on import, so a state file cannot be replayed as another
    /// device.
    pub fn export_state(&self, identity: &str) -> Result<Vec<u8>, Rejected> {
        staging::save(self, identity)
    }

    /// Rebuild a device from `export_state` bytes; a foreign `identity`, an
    /// oversized or corrupt snapshot is rejected.
    pub fn import_state(identity: &str, bytes: &[u8]) -> Result<Device, Rejected> {
        staging::load(bytes, identity)
    }
}

impl Device {
    /// Outstanding KeyPackages this device still holds private material for.
    fn outstanding_key_packages(&self) -> usize {
        self.provider.storage().count_with_label(store::KEY_PACKAGE_LABEL)
    }

    /// Review M4: refuse to mint a ninth outstanding KeyPackage. The caller
    /// prunes with `delete_key_package` (one the relay reported consumed or
    /// expired) or joins (which prunes everything still unused).
    fn key_package_inner(&self) -> Result<Vec<u8>, Rejected> {
        if self.outstanding_key_packages() >= MAX_KEY_PACKAGES { return Err(Rejected("key package limit")); }
        KeyPackage::builder().build(SUITE, &self.provider, &self.signer, self.credential.clone())
            .map_err(rejected)?.key_package().tls_serialize_detached().map_err(rejected)
    }

    /// Delete the private material of one published KeyPackage (TLS-serialized,
    /// as `key_package` returned it). Unknown or foreign packages are rejected,
    /// so a caller cannot use this to probe; a valid one that was already
    /// consumed is rejected the same way.
    fn delete_key_package_inner(&mut self, bytes: &[u8]) -> Result<(), Rejected> {
        bounded(bytes, MAX_WIRE)?;
        let package = KeyPackageIn::tls_deserialize_exact_bytes(bytes).map_err(rejected)?
            .validate(self.provider.crypto(), ProtocolVersion::Mls10).map_err(rejected)?;
        if package.leaf_node().credential() != &self.credential.credential
            || package.leaf_node().signature_key() != &self.credential.signature_key {
            return Err(rejected(()));
        }
        let hash_ref = package.hash_ref(self.provider.crypto()).map_err(rejected)?;
        let storage = self.provider.storage();
        let existing: Option<KeyPackageBundle> =
            <store::Store as StorageProvider<CURRENT_VERSION>>::key_package(storage, &hash_ref).map_err(rejected)?;
        if existing.is_none() { return Err(rejected(())); }
        <store::Store as StorageProvider<CURRENT_VERSION>>::delete_key_package(storage, &hash_ref).map_err(rejected)
    }

    /// Every KeyPackage still unused after a join is dead weight: this facade
    /// holds one group per device, so nothing can consume them any more.
    fn prune_key_packages(&self) -> usize {
        self.provider.storage().remove_with_label(store::KEY_PACKAGE_LABEL)
    }

    fn create_inner(&mut self) -> Result<(), Rejected> {
        if self.group.is_some() { return Err(Rejected("group already exists")); }
        let config = MlsGroupCreateConfig::builder().ciphersuite(SUITE)
            .use_ratchet_tree_extension(true).max_past_epochs(PAST_EPOCHS).build();
        self.group = Some(MlsGroup::new(&self.provider, &self.signer, &config, self.credential.clone()).map_err(rejected)?);
        Ok(())
    }

    /// Welcome-only add kept verbatim for the M0 smokes and worker dispatch.
    fn invite_inner(&mut self, key_packages: &[u8]) -> Result<Vec<u8>, Rejected> {
        let (_, welcome) = self.add_members_inner(key_packages, true)?;
        Ok(welcome)
    }

    /// Same add as `invite_inner`, but returns both wire artifacts the §3.4 v2
    /// relay needs — the commit (POSTed for CAS and total order) and the
    /// multi-target Welcome (targets only), framed as
    /// `u32 LE commit_len || commit || welcome` — and leaves the commit PENDING.
    /// The relay decides the order: events it placed before this commit are still
    /// at the current epoch and must be processed first, so the caller merges only
    /// when it reaches its own commit in the log (`merge_pending`), or discards it
    /// on a 409 (`clear_pending`) and retries after catching up.
    fn invite_with_commit_inner(&mut self, key_packages: &[u8]) -> Result<Vec<u8>, Rejected> {
        let (commit, welcome) = self.add_members_inner(key_packages, false)?;
        let mut framed = Vec::with_capacity(4 + commit.len() + welcome.len());
        framed.extend_from_slice(&(commit.len() as u32).to_le_bytes());
        framed.extend_from_slice(&commit);
        framed.extend_from_slice(&welcome);
        Ok(framed)
    }

    /// Accepts one or more concatenated TLS-serialized KeyPackages; every added
    /// device receives the same multi-target Welcome. Valid at any group size.
    fn add_members_inner(&mut self, key_packages: &[u8], merge: bool) -> Result<(Vec<u8>, Vec<u8>), Rejected> {
        bounded(key_packages, MAX_WIRE)?;
        let mut parsed = Vec::new();
        let mut rest = key_packages;
        while !rest.is_empty() {
            let package = KeyPackageIn::tls_deserialize(&mut rest).map_err(rejected)?
                .validate(self.provider.crypto(), ProtocolVersion::Mls10).map_err(rejected)?;
            parsed.push(package);
        }
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        let (commit, welcome, _) = group.add_members(&self.provider, &self.signer, &parsed).map_err(rejected)?;
        if merge { group.merge_pending_commit(&self.provider).map_err(rejected)?; }
        let commit = commit.tls_serialize_detached().map_err(rejected)?;
        let welcome = welcome.tls_serialize_detached().map_err(rejected)?;
        Ok((commit, welcome))
    }

    fn join_inner(&mut self, bytes: &[u8]) -> Result<(), Rejected> {
        bounded(bytes, MAX_WIRE)?;
        if self.group.is_some() { return Err(Rejected("group already exists")); }
        let message = MlsMessageIn::tls_deserialize_exact_bytes(bytes).map_err(rejected)?;
        let MlsMessageBodyIn::Welcome(welcome) = message.extract() else { return Err(rejected(())); };
        // Joiners must also carry the ratchet tree in the Welcomes THEY later create:
        // the default join config turns the extension off, so a Welcome from any
        // member other than the creator could not be joined (tree = None here).
        let config = MlsGroupJoinConfig::builder().use_ratchet_tree_extension(true)
            .max_past_epochs(PAST_EPOCHS).build();
        let staged = StagedWelcome::new_from_welcome(&self.provider,
            &config, welcome, None).map_err(rejected)?;
        self.group = Some(staged.into_group(&self.provider).map_err(rejected)?);
        // OpenMLS deleted the consumed KeyPackage; the rest can never be used (M4).
        self.prune_key_packages();
        Ok(())
    }

    fn encrypt_inner(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> {
        let (room, rest) = split_identity(bytes)?;
        let (client_id, plaintext) = split_identity(rest)?;
        bounded(plaintext, MAX_ATTACHMENT)?;
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        // Ephemeral in OpenMLS: `create_message` clears the AAD again on
        // success, and any failure retires the device — it never leaks into a
        // later commit.
        let aad = aad_bytes(room.as_bytes(), group.group_id().as_slice(),
            self.credential.credential.serialized_content(), client_id.as_bytes(), group.epoch().as_u64());
        group.set_aad(aad);
        group.create_message(&self.provider, &self.signer, plaintext).map_err(rejected)?
            .tls_serialize_detached().map_err(rejected)
    }

    /// Shared §3.6 decrypt path: MLS-authenticate, then require the sender's
    /// AAD to name exactly this room, this group, the MLS-authenticated sender
    /// device and the epoch the wire message itself carries.
    ///
    /// Review H1 — attribution: the AAD `client_id` is the label the *sender*
    /// declared for itself. It is bound here to the actor the receiver can
    /// verify independently: `expected_client` when the lane has a policy/pin
    /// map (trusted lane: the pinned peer actor), otherwise the roster identity
    /// (`members()`) of the MLS-authenticated sender leaf. A mismatch is a
    /// rejection like any other AAD mismatch — the caller rolls the ratchet
    /// state back — so a member cannot sign a message as someone else.
    fn decrypt_checked_inner(&mut self, room: &str, ciphertext: &[u8], expected_client: Option<&str>)
        -> Result<(Vec<u8>, AuthenticatedSender), Rejected> {
        let message = MlsMessageIn::tls_deserialize_exact_bytes(ciphertext).map_err(rejected)?
            .try_into_protocol_message().map_err(rejected)?;
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        let processed = group.process_message(&self.provider, message).map_err(rejected)?;
        let parsed = parse_aad(processed.aad()).ok_or_else(|| rejected(()))?;
        let (sender_device, credential, signature_key) = match processed.sender() {
            Sender::Member(index) => match group.members().find(|m| m.index == *index) {
                // Every device in this facade carries a BasicCredential whose
                // serialized content is exactly the identity string.
                Some(member) =>
                    (member.credential.serialized_content().to_vec(), member.credential, Some(member.signature_key)),
                // Review 2 J-HB (#231): a message from a past epoch (within
                // PAST_EPOCHS) whose sender a later commit removed — sent
                // legitimately while it was a member. OpenMLS authenticated it
                // against that epoch's leaves; `credential()` is that sender.
                None => {
                    let credential = processed.credential().clone();
                    (credential.serialized_content().to_vec(), credential, None)
                }
            },
            _ => return Err(rejected(())),
        };
        let epoch = processed.epoch().as_u64();
        let content = processed.into_content();
        if parsed.room != room.as_bytes() || parsed.group_id != group.group_id().as_slice()
            || parsed.sender_device != sender_device || parsed.epoch != epoch {
            return Err(rejected(()));
        }
        let expected_client = expected_client.map(str::as_bytes).unwrap_or(&sender_device);
        if parsed.client_id != expected_client { return Err(Rejected("sender attribution rejected")); }
        let ProcessedMessageContent::ApplicationMessage(message) = content else { return Err(rejected(())); };
        Ok((message.into_bytes(), AuthenticatedSender {
            device: sender_device, client_id: parsed.client_id, credential, signature_key }))
    }

    /// Input: `u32 LE room_len ‖ room ‖ ciphertext`. Output: `frame_decrypt`
    /// (`DECRYPT_FORMAT` 2) — sender device, bound client id, plaintext.
    fn decrypt_inner(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> {
        self.decrypt_with(bytes, None)
    }

    /// `decrypt_inner` with the actor the lane can verify independently.
    pub(crate) fn decrypt_with(&mut self, bytes: &[u8], expected_client: Option<&str>) -> Result<Vec<u8>, Rejected> {
        let (room, ciphertext) = split_identity(bytes)?;
        bounded(ciphertext, MAX_WIRE)?;
        let (plaintext, sender) = self.decrypt_checked_inner(room, ciphertext, expected_client)?;
        Ok(frame_decrypt(&sender.device, &sender.client_id, &plaintext))
    }

    /// Remove the member whose leaf signing key equals `key` (never our own leaf).
    /// The target is identified by its pinned public key, not by a leaf index or label.
    /// `merge = false` leaves the commit pending for the v2 relay flow (see
    /// `invite_with_commit_inner`); the M0 `remove` keeps merging immediately.
    fn remove_member_inner(&mut self, key: &[u8], merge: bool) -> Result<Vec<u8>, Rejected> {
        if key.len() != 32 || key == self.signer.public() { return Err(rejected(())); }
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        let targets: Vec<LeafNodeIndex> = group.members().filter(|m| m.signature_key == key).map(|m| m.index).collect();
        let [target] = targets[..] else { return Err(rejected(())); };
        let (commit, _, _) = group.remove_members(&self.provider, &self.signer, &[target]).map_err(rejected)?;
        if merge { group.merge_pending_commit(&self.provider).map_err(rejected)?; }
        commit.tls_serialize_detached().map_err(rejected)
    }

    /// Process an incoming commit into a `StagedCommit` (not merged).
    fn process_commit(&mut self, bytes: &[u8]) -> Result<StagedCommit, Rejected> {
        bounded(bytes, MAX_WIRE)?;
        let message = MlsMessageIn::tls_deserialize_exact_bytes(bytes).map_err(rejected)?
            .try_into_protocol_message().map_err(rejected)?;
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        let processed = group.process_message(&self.provider, message).map_err(rejected)?;
        let ProcessedMessageContent::StagedCommitMessage(commit) = processed.into_content() else { return Err(rejected(())); };
        Ok(*commit)
    }

    fn apply_commit_inner(&mut self, bytes: &[u8]) -> Result<(), Rejected> {
        if self.staged.is_some() { return Err(Rejected("commit already staged")); }
        let commit = self.process_commit(bytes)?;
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        group.merge_staged_commit(&self.provider, commit).map_err(rejected)
    }

    /// Review M1 (step one of two) + review 2 J-MB (#231): authenticate and
    /// stage an incoming commit and report every identity→signing-key change it
    /// carries — not merging. Wire form (`STAGE_REPORT_FORMAT` 2), four
    /// `frame_members` sections appended in this order:
    /// 1. adds — the commit's add proposals (identity, key package key);
    /// 2. removes — the members it removes (identity, key as of this epoch);
    /// 3. update proposals — each committed member leaf replacement as
    ///    (identity, NEW key); a member can only update its own leaf, but the
    ///    *committer* may carry another member's proposal in its commit, so a
    ///    key-pinning caller must see it;
    /// 4. committer path — 0 or 1 entries: the committer's own new leaf
    ///    (`update_path_leaf_node`). OpenMLS 0.9 emits a path for every member
    ///    commit this facade sees (add, remove and self-update alike), so the
    ///    path section is the committer's authoritative post-commit
    ///    identity→key pair — the one identity change sections 1–2 cannot
    ///    express (J-MB: the committer can rotate its signing key without any
    ///    add/remove/update proposal). Section 3 covers the same change for a
    ///    *member* leaf: OpenMLS's public builders commit proposals by
    ///    reference, and this relay lane carries no standalone proposals, so a
    ///    commit referencing an unseen update proposal is refused below
    ///    (`MissingProposal`) — the update section is defence in depth for
    ///    committers that inline proposals.
    /// A caller derives the post-merge roster by applying 1–4 in order (the
    /// path overrides an update proposal naming the committer's own leaf);
    /// several updates for one identity are a policy matter, reported as-is.
    fn stage_commit_inner(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> {
        if self.staged.is_some() { return Err(Rejected("commit already staged")); }
        let commit = self.process_commit(bytes)?;
        let group = self.group.as_ref().ok_or_else(|| rejected(()))?;
        let adds = policy::roster_from_leaves(commit.add_proposals()
            .map(|p| p.add_proposal().key_package().leaf_node().clone()))?;
        let removed: Vec<LeafNodeIndex> = commit.remove_proposals().map(|p| p.remove_proposal().removed()).collect();
        let removes = policy::roster_from_members(group.members().filter(|m| removed.contains(&m.index)))?;
        let updates = policy::roster_from_leaves(commit.update_proposals()
            .map(|p| p.update_proposal().leaf_node().clone()))?;
        let path = policy::roster_from_leaves(commit.update_path_leaf_node().cloned().into_iter())?;
        let mut out = policy::frame_members(&adds);
        out.extend_from_slice(&policy::frame_members(&removes));
        out.extend_from_slice(&policy::frame_members(&updates));
        out.extend_from_slice(&policy::frame_members(&path));
        self.staged = Some(commit);
        Ok(out)
    }

    fn merge_staged_inner(&mut self) -> Result<(), Rejected> {
        let commit = self.staged.take().ok_or(Rejected("nothing staged"))?;
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        group.merge_staged_commit(&self.provider, commit).map_err(rejected)
    }

    /// Drop a staged commit. The handshake ratchet step that authenticated it
    /// was consumed, so the same commit cannot be staged again: discarding is
    /// a policy refusal of that epoch, after which the device must leave or
    /// be re-added. The device itself stays usable at the current epoch.
    fn discard_staged_inner(&mut self) -> Result<(), Rejected> {
        self.staged.take().map(drop).ok_or(Rejected("nothing staged"))
    }

    /// The relay accepted our commit and every event it ordered before it has been
    /// processed: move to the new epoch. Rejected when nothing is pending.
    fn merge_pending_inner(&mut self) -> Result<(), Rejected> {
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        if group.pending_commit().is_none() { return Err(rejected(())); }
        group.merge_pending_commit(&self.provider).map_err(rejected)
    }

    /// The relay refused our commit (409): drop it and stay at the current epoch,
    /// so the missed events can be applied before a retry. Rejected when nothing
    /// is pending.
    fn clear_pending_inner(&mut self) -> Result<(), Rejected> {
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        if group.pending_commit().is_none() { return Err(rejected(())); }
        group.clear_pending_commit(self.provider.storage()).map_err(rejected)
    }
}

impl Device {
    fn run<T>(&mut self, operation: impl FnOnce(&mut Self) -> Result<T, Rejected>) -> Result<T, Rejected> {
        if self.retired { return Err(Rejected("device retired")); }
        match operation(self) {
            Ok(value) => Ok(value),
            Err(error) => {
                // OpenMLS may consume ratchet keys before authentication fails.
                // Never reuse uncertain state; this experiment has no recovery.
                self.retired = true;
                self.group = None;
                self.staged = None;
                Err(error)
            }
        }
    }
}

#[wasm_bindgen]
impl Device {
    /// The M4 cap is a pure precondition: it rejects without retiring the device.
    pub fn key_package(&mut self) -> Result<Vec<u8>, Rejected> {
        if !self.retired && self.outstanding_key_packages() >= MAX_KEY_PACKAGES { return Err(Rejected("key package limit")); }
        self.run(|s| s.key_package_inner())
    }
    /// Pure bookkeeping (M4): a rejection leaves the device usable.
    pub fn delete_key_package(&mut self, bytes: &[u8]) -> Result<(), Rejected> {
        if self.retired { return Err(Rejected("device retired")); }
        self.delete_key_package_inner(bytes)
    }
    pub fn key_packages_outstanding(&self) -> u32 { self.outstanding_key_packages() as u32 }
    pub fn decrypt_format() -> u32 { DECRYPT_FORMAT }
    /// The `stage_commit` report wire format JS callers parse
    /// (`STAGE_REPORT_FORMAT`).
    pub fn stage_report_format() -> u32 { STAGE_REPORT_FORMAT }
    /// The "already staged" / "nothing staged" preconditions are pure: they
    /// touch no ratchet state, so they reject without retiring the device.
    pub fn stage_commit(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> {
        if !self.retired && self.staged.is_some() { return Err(Rejected("commit already staged")); }
        self.run(|s| s.stage_commit_inner(bytes))
    }
    pub fn merge_staged(&mut self) -> Result<(), Rejected> {
        if !self.retired && self.staged.is_none() { return Err(Rejected("nothing staged")); }
        self.run(|s| s.merge_staged_inner())
    }
    pub fn discard_staged(&mut self) -> Result<(), Rejected> {
        if !self.retired && self.staged.is_none() { return Err(Rejected("nothing staged")); }
        self.run(|s| s.discard_staged_inner())
    }
    pub fn create(&mut self) -> Result<(), Rejected> { self.run(|s| s.create_inner()) }
    pub fn invite(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> { self.run(|s| s.invite_inner(bytes)) }
    pub fn invite_with_commit(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> { self.run(|s| s.invite_with_commit_inner(bytes)) }
    pub fn join(&mut self, bytes: &[u8]) -> Result<(), Rejected> { self.run(|s| s.join_inner(bytes)) }
    pub fn encrypt(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> { self.run(|s| s.encrypt_inner(bytes)) }
    pub fn decrypt(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> { self.run(|s| s.decrypt_inner(bytes)) }
    pub fn remove_member(&mut self, key: &[u8]) -> Result<Vec<u8>, Rejected> { self.run(|s| s.remove_member_inner(key, true)) }
    pub fn remove_member_pending(&mut self, key: &[u8]) -> Result<Vec<u8>, Rejected> { self.run(|s| s.remove_member_inner(key, false)) }
    /// "Nothing pending" is a pure precondition (review 2 J-MA): merging a
    /// foreign commit clears an own pending commit (OpenMLS), so a caller that
    /// catches up first and then clears/merges must get a rejection, not a
    /// retired device.
    pub fn merge_pending(&mut self) -> Result<(), Rejected> {
        if !self.retired && !self.has_pending() { return Err(Rejected("nothing pending")); }
        self.run(|s| s.merge_pending_inner())
    }
    pub fn clear_pending(&mut self) -> Result<(), Rejected> {
        if !self.retired && !self.has_pending() { return Err(Rejected("nothing pending")); }
        self.run(|s| s.clear_pending_inner())
    }
    /// Whether an own commit is pending (the relay flow's two-phase state).
    pub fn has_pending(&self) -> bool {
        self.group.as_ref().is_some_and(|g| g.pending_commit().is_some())
    }
    pub fn apply_commit(&mut self, bytes: &[u8]) -> Result<(), Rejected> {
        if !self.retired && self.staged.is_some() { return Err(Rejected("commit already staged")); }
        self.run(|s| s.apply_commit_inner(bytes))
    }
}

mod migrate;
mod policy;
/// Durable-lane byte contract for `members`, `members_after_pending`,
/// `fingerprint`, `policy_fingerprint`, `sign_approval` — native hosts (ios-ffi)
/// dispatch through it so their bytes match `web/durable-worker.js` (#275).
pub use policy::policy_wire;
mod record;
mod session;
mod staging;
mod store;
/// Host-target suites (64-bit `usize`): storage v2, policy evidence, the full
/// relay-flow harness. The wasm32 gate runs `tests_wasm32` instead — the same
/// vectors plus the 32-bit-specific guards, on the shipped target.
#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests_v2;
/// Real-target tests (wasm32-unknown-unknown, CI `native-mls` job via the
/// pinned release's wasm-bindgen-test-runner in node): the 32-bit `usize`
/// length guards (review M3) and the stage-report wire format (J-MB).
#[cfg(all(test, target_arch = "wasm32"))]
mod tests_wasm32;

mod trust;
