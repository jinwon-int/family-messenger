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
        bounded(bytes, 16384)?;
        self.group.as_mut().ok_or_else(|| rejected(()))?
            .create_message(&self.provider, &self.signer, bytes).map_err(rejected)?
            .tls_serialize_detached().map_err(rejected)
    }

    fn decrypt_inner(&mut self, bytes: &[u8]) -> Result<Vec<u8>, Rejected> {
        bounded(bytes, MAX_WIRE)?;
        let message = MlsMessageIn::tls_deserialize_exact_bytes(bytes).map_err(rejected)?
            .try_into_protocol_message().map_err(rejected)?;
        let processed = self.group.as_mut().ok_or_else(|| rejected(()))?
            .process_message(&self.provider, message).map_err(rejected)?;
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) => Ok(message.into_bytes()),
            _ => Err(rejected(())),
        }
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
mod session;
mod staging;
mod store;
#[cfg(test)]
mod tests_v2;

mod trust;
