//! Memory-only synthetic qualification; no account trust or durable state.
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use tls_codec::Serialize;
use wasm_bindgen::prelude::*;

const SUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
const MAX_WIRE: usize = 65536;
fn rejected<T>(_: T) -> JsValue { JsValue::from_str("MLS operation rejected") }
fn bounded(bytes: &[u8], max: usize) -> Result<(), JsValue> {
    if bytes.is_empty() || bytes.len() > max { Err(JsValue::from_str("size rejected")) } else { Ok(()) }
}

/// One fresh disposable device, with a single in-memory group.
#[wasm_bindgen]
pub struct Device {
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
    group: Option<MlsGroup>,
    retired: bool,
}

#[wasm_bindgen]
impl Device {
    #[wasm_bindgen(constructor)]
    pub fn new(identity: &str) -> Result<Device, JsValue> {
        if !["alice", "bob", "outsider", "alice-second"].contains(&identity) {
            return Err(JsValue::from_str("synthetic identities only"));
        }
        let provider = OpenMlsRustCrypto::default();
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
    fn key_package_inner(&self) -> Result<Vec<u8>, JsValue> {
        KeyPackage::builder().build(SUITE, &self.provider, &self.signer, self.credential.clone())
            .map_err(rejected)?.key_package().tls_serialize_detached().map_err(rejected)
    }

    fn create_inner(&mut self) -> Result<(), JsValue> {
        if self.group.is_some() { return Err(JsValue::from_str("group already exists")); }
        let config = MlsGroupCreateConfig::builder().ciphersuite(SUITE)
            .use_ratchet_tree_extension(true).build();
        self.group = Some(MlsGroup::new(&self.provider, &self.signer, &config, self.credential.clone()).map_err(rejected)?);
        Ok(())
    }

    /// Synthetic delivery coordinator accepts the commit before forwarding Welcome.
    fn invite_inner(&mut self, key_package: &[u8]) -> Result<Vec<u8>, JsValue> {
        bounded(key_package, MAX_WIRE)?;
        let package = KeyPackageIn::tls_deserialize_exact_bytes(key_package).map_err(rejected)?
            .validate(self.provider.crypto(), ProtocolVersion::Mls10).map_err(rejected)?;
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        if group.members().count() != 1 { return Err(JsValue::from_str("two-member experiment only")); }
        let (_, welcome, _) = group.add_members(&self.provider, &self.signer, &[package]).map_err(rejected)?;
        group.merge_pending_commit(&self.provider).map_err(rejected)?;
        welcome.tls_serialize_detached().map_err(rejected)
    }

    fn join_inner(&mut self, bytes: &[u8]) -> Result<(), JsValue> {
        bounded(bytes, MAX_WIRE)?;
        if self.group.is_some() { return Err(JsValue::from_str("group already exists")); }
        let message = MlsMessageIn::tls_deserialize_exact_bytes(bytes).map_err(rejected)?;
        let MlsMessageBodyIn::Welcome(welcome) = message.extract() else { return Err(rejected(())); };
        let staged = StagedWelcome::new_from_welcome(&self.provider,
            &MlsGroupJoinConfig::default(), welcome, None).map_err(rejected)?;
        self.group = Some(staged.into_group(&self.provider).map_err(rejected)?);
        Ok(())
    }

    fn encrypt_inner(&mut self, bytes: &[u8]) -> Result<Vec<u8>, JsValue> {
        bounded(bytes, 16384)?;
        self.group.as_mut().ok_or_else(|| rejected(()))?
            .create_message(&self.provider, &self.signer, bytes).map_err(rejected)?
            .tls_serialize_detached().map_err(rejected)
    }

    fn decrypt_inner(&mut self, bytes: &[u8]) -> Result<Vec<u8>, JsValue> {
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

    /// Remove the sole invited leaf in this two-member experiment.
    fn remove_invitee_inner(&mut self) -> Result<Vec<u8>, JsValue> {
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        if group.members().count() != 2 { return Err(rejected(())); }
        let (commit, _, _) = group.remove_members(&self.provider, &self.signer, &[LeafNodeIndex::new(1)]).map_err(rejected)?;
        group.merge_pending_commit(&self.provider).map_err(rejected)?;
        commit.tls_serialize_detached().map_err(rejected)
    }

    fn apply_commit_inner(&mut self, bytes: &[u8]) -> Result<(), JsValue> {
        bounded(bytes, MAX_WIRE)?;
        let message = MlsMessageIn::tls_deserialize_exact_bytes(bytes).map_err(rejected)?
            .try_into_protocol_message().map_err(rejected)?;
        let group = self.group.as_mut().ok_or_else(|| rejected(()))?;
        let processed = group.process_message(&self.provider, message).map_err(rejected)?;
        let ProcessedMessageContent::StagedCommitMessage(commit) = processed.into_content() else { return Err(rejected(())); };
        group.merge_staged_commit(&self.provider, *commit).map_err(rejected)
    }
}

impl Device {
    fn run<T>(&mut self, operation: impl FnOnce(&mut Self) -> Result<T, JsValue>) -> Result<T, JsValue> {
        if self.retired { return Err(JsValue::from_str("device retired")); }
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
    pub fn key_package(&mut self) -> Result<Vec<u8>, JsValue> { self.run(|s| s.key_package_inner()) }
    pub fn create(&mut self) -> Result<(), JsValue> { self.run(|s| s.create_inner()) }
    pub fn invite(&mut self, bytes: &[u8]) -> Result<Vec<u8>, JsValue> { self.run(|s| s.invite_inner(bytes)) }
    pub fn join(&mut self, bytes: &[u8]) -> Result<(), JsValue> { self.run(|s| s.join_inner(bytes)) }
    pub fn encrypt(&mut self, bytes: &[u8]) -> Result<Vec<u8>, JsValue> { self.run(|s| s.encrypt_inner(bytes)) }
    pub fn decrypt(&mut self, bytes: &[u8]) -> Result<Vec<u8>, JsValue> { self.run(|s| s.decrypt_inner(bytes)) }
    pub fn remove_invitee(&mut self) -> Result<Vec<u8>, JsValue> { self.run(|s| s.remove_invitee_inner()) }
    pub fn apply_commit(&mut self, bytes: &[u8]) -> Result<(), JsValue> { self.run(|s| s.apply_commit_inner(bytes)) }
}
