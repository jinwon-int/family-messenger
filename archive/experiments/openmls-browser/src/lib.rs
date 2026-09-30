//! Memory-only synthetic qualification; no account trust or durable state.
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::RustCrypto;
use tls_codec::{Deserialize as TlsDeserialize, Serialize};
use wasm_bindgen::prelude::*;

const SUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
const MAX_WIRE: usize = 65536;
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
    !identity.is_empty() && identity.len() <= 64
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
    pub epoch: u64,
}

/// Strict inverse of `aad_bytes`: exact bounds (identities ≤ 64 bytes like
/// `valid_identity`, group id ≤ 64, non-empty), `valid_identity` text for
/// room/sender/client, no trailing bytes. The `client_id` field is validated
/// for shape but not returned: nothing on the receiving side can check it
/// independently here — its device binding is the §3.3 roster check.
pub(crate) fn parse_aad(bytes: &[u8]) -> Option<Aad> {
    fn field(rest: &mut &[u8], max: usize, identity: bool) -> Option<Vec<u8>> {
        if rest.len() < 4 { return None; }
        let len = u32::from_le_bytes(rest[..4].try_into().ok()?) as usize;
        if rest.len() - 4 < len || len > max { return None; }
        let (value, tail) = rest.split_at(4 + len);
        let value = &value[4..];
        *rest = tail;
        if identity { valid_identity(std::str::from_utf8(value).ok()?).then_some(())?; }
        Some(value.to_vec())
    }
    let mut rest = bytes;
    let room = field(&mut rest, 64, true)?;
    let group_id = field(&mut rest, 64, false)?;
    if group_id.is_empty() { return None; }
    let sender_device = field(&mut rest, 64, true)?;
    field(&mut rest, 64, true)?;
    if rest.len() != 8 { return None; }
    let epoch = u64::from_le_bytes(rest.try_into().ok()?);
    Some(Aad { room, group_id, sender_device, epoch })
}

/// `u32 LE length ‖ identity ‖ rest` — the caller-declared part of the
/// encrypt/decrypt input (the room, then the client id for encrypt). The
/// caller declares these per message; trust stays with the MLS checks.
pub(crate) fn split_identity(bytes: &[u8]) -> Result<(&str, &[u8]), Rejected> {
    if bytes.len() < 4 { return Err(rejected(())); }
    let len = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
    let rest = bytes.get(4 + len..).ok_or_else(|| rejected(()))?;
    let identity = std::str::from_utf8(&bytes[4..4 + len]).map_err(|_| rejected(()))?;
    if !valid_identity(identity) { return Err(rejected(())); }
    Ok((identity, rest))
}

/// MLS-authenticated application sender as this facade's devices see it: the
/// AAD-checked device identity, the roster credential and leaf signing key.
pub(crate) struct AuthenticatedSender {
    pub device: Vec<u8>,
    pub credential: Credential,
    pub signature_key: Vec<u8>,
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
        Ok(Self { provider, signer, credential, group: None, retired: false })
    }

}

impl Device {
    fn key_package_inner(&self) -> Result<Vec<u8>, Rejected> {
        KeyPackage::builder().build(SUITE, &self.provider, &self.signer, self.credential.clone())
            .map_err(rejected)?.key_package().tls_serialize_detached().map_err(rejected)
    }

    fn create_inner(&mut self) -> Result<(), Rejected> {
        if self.group.is_some() { return Err(Rejected("group already exists")); }
        let config = MlsGroupCreateConfig::builder().ciphersuite(SUITE)
            .use_ratchet_tree_extension(true).build();
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
        let config = MlsGroupJoinConfig::builder().use_ratchet_tree_extension(true).build();
        let staged = StagedWelcome::new_from_welcome(&self.provider,
            &config, welcome, None).map_err(rejected)?;
        self.group = Some(staged.into_group(&self.provider).map_err(rejected)?);
        Ok(())
    }

    fn encrypt_inner(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> {
        let (room, rest) = split_identity(bytes)?;
        let (client_id, plaintext) = split_identity(rest)?;
        bounded(plaintext, 16384)?;
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

    /// MLS-authenticated application sender as this facade's devices see it:
    /// the AAD-checked device identity, the roster credential and leaf key.
    /// Shared §3.6 decrypt path: MLS-authenticate, then require the sender's
    /// AAD to name exactly this room, this group, the MLS-authenticated sender
    /// device and the epoch the wire message itself carries. `client_id` is
    /// shape-checked here; its binding to the device is the §3.3 roster check,
    /// which the client validates after MLS processing.
    fn decrypt_checked_inner(&mut self, room: &str, ciphertext: &[u8]) -> Result<(Vec<u8>, AuthenticatedSender), Rejected> {
        let message = MlsMessageIn::tls_deserialize_exact_bytes(ciphertext).map_err(rejected)?
            .try_into_protocol_message().map_err(rejected)?;
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        let processed = group.process_message(&self.provider, message).map_err(rejected)?;
        let parsed = parse_aad(processed.aad()).ok_or_else(|| rejected(()))?;
        let (sender_device, credential, signature_key) = match processed.sender() {
            Sender::Member(index) => {
                let member = group.members().find(|m| m.index == *index).ok_or_else(|| rejected(()))?;
                // Every device in this facade carries a BasicCredential whose
                // serialized content is exactly the identity string.
                (member.credential.serialized_content().to_vec(), member.credential, member.signature_key)
            }
            _ => return Err(rejected(())),
        };
        let epoch = processed.epoch().as_u64();
        let content = processed.into_content();
        if parsed.room != room.as_bytes() || parsed.group_id != group.group_id().as_slice()
            || parsed.sender_device != sender_device || parsed.epoch != epoch {
            return Err(rejected(()));
        }
        let ProcessedMessageContent::ApplicationMessage(message) = content else { return Err(rejected(())); };
        Ok((message.into_bytes(), AuthenticatedSender { device: sender_device, credential, signature_key }))
    }

    /// Input: `u32 LE room_len ‖ room ‖ ciphertext`.
    fn decrypt_inner(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> {
        let (room, ciphertext) = split_identity(bytes)?;
        bounded(ciphertext, MAX_WIRE)?;
        self.decrypt_checked_inner(room, ciphertext).map(|(plaintext, _)| plaintext)
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

    fn apply_commit_inner(&mut self, bytes: &[u8]) -> Result<(), Rejected> {
        bounded(bytes, MAX_WIRE)?;
        let message = MlsMessageIn::tls_deserialize_exact_bytes(bytes).map_err(rejected)?
            .try_into_protocol_message().map_err(rejected)?;
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        let processed = group.process_message(&self.provider, message).map_err(rejected)?;
        let ProcessedMessageContent::StagedCommitMessage(commit) = processed.into_content() else { return Err(rejected(())); };
        group.merge_staged_commit(&self.provider, *commit).map_err(rejected)
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
                Err(error)
            }
        }
    }
}

#[wasm_bindgen]
impl Device {
    pub fn key_package(&mut self) -> Result<Vec<u8>, Rejected> { self.run(|s| s.key_package_inner()) }
    pub fn create(&mut self) -> Result<(), Rejected> { self.run(|s| s.create_inner()) }
    pub fn invite(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> { self.run(|s| s.invite_inner(bytes)) }
    pub fn invite_with_commit(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> { self.run(|s| s.invite_with_commit_inner(bytes)) }
    pub fn join(&mut self, bytes: &[u8]) -> Result<(), Rejected> { self.run(|s| s.join_inner(bytes)) }
    pub fn encrypt(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> { self.run(|s| s.encrypt_inner(bytes)) }
    pub fn decrypt(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> { self.run(|s| s.decrypt_inner(bytes)) }
    pub fn remove_member(&mut self, key: &[u8]) -> Result<Vec<u8>, Rejected> { self.run(|s| s.remove_member_inner(key, true)) }
    pub fn remove_member_pending(&mut self, key: &[u8]) -> Result<Vec<u8>, Rejected> { self.run(|s| s.remove_member_inner(key, false)) }
    pub fn merge_pending(&mut self) -> Result<(), Rejected> { self.run(|s| s.merge_pending_inner()) }
    pub fn clear_pending(&mut self) -> Result<(), Rejected> { self.run(|s| s.clear_pending_inner()) }
    pub fn apply_commit(&mut self, bytes: &[u8]) -> Result<(), Rejected> { self.run(|s| s.apply_commit_inner(bytes)) }
}

mod migrate;
mod policy;
mod record;
mod session;
mod staging;
mod store;
#[cfg(test)]
mod tests_v2;

mod trust;
