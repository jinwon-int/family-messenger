//! Synthetic first-device pin checks using validated MLS credentials/signatures.
use super::*;

fn expected(actor: &str, key: &[u8]) -> Result<CredentialWithKey, Rejected> {
    if !valid_identity(actor) || key.len() != 32 {
        return Err(rejected(()));
    }
    Ok(CredentialWithKey {credential: BasicCredential::new(actor.as_bytes().to_vec()).into(), signature_key: key.to_vec().into()})
}
#[wasm_bindgen]
pub fn verify_device_package(bytes: &[u8], actor: &str, key: &[u8]) -> Result<(), Rejected> {
    bounded(bytes, MAX_WIRE)?;
    let expected = expected(actor, key)?;
    let provider = Provider::default();
    let kp = KeyPackageIn::tls_deserialize_exact_bytes(bytes).map_err(rejected)?
        .validate(provider.crypto(), ProtocolVersion::Mls10).map_err(rejected)?;
    if kp.leaf_node().credential() != &expected.credential || kp.leaf_node().signature_key() != &expected.signature_key {
        return Err(rejected(()));
    }
    Ok(())
}
#[wasm_bindgen]
impl Device {
    /// Public key only; no signer serialization leaves the worker.
    pub fn public_key(&mut self) -> Result<Vec<u8>, Rejected> {
        self.run(|s| Ok(s.signer.public().to_vec()))
    }
    pub fn invite_trusted(&mut self, bytes: &[u8], actor: &str, key: &[u8]) -> Result<Vec<u8>, Rejected> {
        self.run(|s| s.invite_trusted_inner(bytes, actor, key))
    }
    pub fn join_trusted(&mut self, bytes: &[u8], actor: &str, key: &[u8]) -> Result<(), Rejected> {
        self.run(|s| s.join_trusted_inner(bytes, actor, key))
    }
}

impl Device {
    /// Add only a KeyPackage whose credential and signing key equal the pin.
    pub(crate) fn invite_trusted_inner(&mut self, bytes: &[u8], actor: &str, key: &[u8]) -> Result<Vec<u8>, Rejected> {
        verify_device_package(bytes, actor, key)?;
        self.invite_inner(bytes)
    }
    /// Join, then require exactly our own leaf and the pinned peer's leaf.
    pub(crate) fn join_trusted_inner(&mut self, bytes: &[u8], actor: &str, key: &[u8]) -> Result<(), Rejected> {
        let expected = expected(actor, key)?;
        self.join_inner(bytes)?;
        let group = self.group.as_ref().ok_or_else(|| rejected(()))?;
        let members: Vec<_> = group.members().collect();
        if members.len() < 2 {return Err(rejected(()));}
        let own = members.iter().filter(|m| m.credential == self.credential.credential && m.signature_key == self.signer.public()).count();
        let peer = members.iter().filter(|m| m.credential == expected.credential && m.signature_key == key).count();
        if own != 1 || peer != 1 || self.signer.public() == key {return Err(rejected(()));}
        Ok(())
    }
}

impl Device {
    // Return the framed plaintext (`frame_decrypt`, DECRYPT_FORMAT 2) only after
    // checking the actual MLS-authenticated sender, credential and leaf signing
    // key, plus the §3.6 AAD binding with the pinned actor as the only admissible
    // client id (H1). Inner application labels are not proof.
    pub(crate) fn decrypt_peer_inner(&mut self, bytes: &[u8], actor: &str, key: &[u8]) -> Result<Vec<u8>, Rejected> {
        let expected = expected(actor,key)?;
        let (room, ciphertext) = split_identity(bytes)?;
        bounded(ciphertext, MAX_WIRE)?;
        let (plaintext, sender) = self.decrypt_checked_inner(room, ciphertext, Some(actor))?;
        // The pin binds the same identity the AAD was required to carry.
        // A past-epoch message from a leaf no longer in the tree carries no
        // signing key to compare against the pin: refused in this lane.
        if sender.device != expected.credential.serialized_content()
            || sender.credential != expected.credential || sender.signature_key.as_deref() != Some(key) {
            return Err(rejected(()));
        }
        Ok(frame_decrypt(&sender.device, &sender.client_id, &plaintext))
    }
}
