//! Synthetic first-device pin checks using validated MLS credentials/signatures.
use super::*;

fn expected(actor: &str, key: &[u8]) -> Result<CredentialWithKey, JsValue> {
    if !["alice", "bob", "outsider", "alice-second"].contains(&actor) || key.len() != 32 {
        return Err(rejected(()));
    }
    Ok(CredentialWithKey {credential: BasicCredential::new(actor.as_bytes().to_vec()).into(), signature_key: key.to_vec().into()})
}
#[wasm_bindgen]
pub fn verify_device_package(bytes: &[u8], actor: &str, key: &[u8]) -> Result<(), JsValue> {
    bounded(bytes, MAX_WIRE)?;
    let expected = expected(actor, key)?;
    let provider = OpenMlsRustCrypto::default();
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
    pub fn public_key(&mut self) -> Result<Vec<u8>, JsValue> {
        self.run(|s| Ok(s.signer.public().to_vec()))
    }
    pub fn invite_trusted(&mut self, bytes: &[u8], actor: &str, key: &[u8]) -> Result<Vec<u8>, JsValue> {
        self.run(|s| {
            verify_device_package(bytes, actor, key)?;
            s.invite_inner(bytes)
        })
    }
    pub fn join_trusted(&mut self, bytes: &[u8], actor: &str, key: &[u8]) -> Result<(), JsValue> {
        self.run(|s| {
            let expected = expected(actor, key)?;
            s.join_inner(bytes)?;
            let group = s.group.as_ref().ok_or_else(|| rejected(()))?;
            let members: Vec<_> = group.members().collect();
            if members.len() != 2 {return Err(rejected(()));}
            let own = members.iter().filter(|m| m.credential == s.credential.credential && m.signature_key == s.signer.public()).count();
            let peer = members.iter().filter(|m| m.credential == expected.credential && m.signature_key == key).count();
            if own != 1 || peer != 1 || s.signer.public() == key {return Err(rejected(()));}
            Ok(())
        })
    }
}
