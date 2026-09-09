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

impl Device {
    // Return plaintext only after checking the actual MLS-authenticated sender,
    // credential and leaf signing key. Inner application labels are not proof.
    pub(crate) fn decrypt_peer_inner(&mut self, bytes: &[u8], actor: &str, key: &[u8]) -> Result<Vec<u8>, JsValue> {
        bounded(bytes, MAX_WIRE)?;
        let expected = expected(actor,key)?;
        let message = MlsMessageIn::tls_deserialize_exact_bytes(bytes).map_err(rejected)?
            .try_into_protocol_message().map_err(rejected)?;
        let group=self.group.as_mut().ok_or_else(||rejected(()))?;
        let processed=group.process_message(&self.provider,message).map_err(rejected)?;
        let Sender::Member(index)=processed.sender() else {return Err(rejected(()));};
        let member=group.members().find(|m|m.index==*index).ok_or_else(||rejected(()))?;
        if processed.credential()!=&expected.credential || member.credential!=expected.credential || member.signature_key!=key {
            return Err(rejected(()));
        }
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message)=>Ok(message.into_bytes()),
            _=>Err(rejected(())),
        }
    }
}

impl Device {
    // Rekey the leaf's encryption material, retaining independently pinned signing
    // keys. Do not merge here: old-epoch inbound traffic may precede acceptance.
    pub(crate) fn stage_update_inner(&mut self, aad: &[u8]) -> Result<Vec<u8>, JsValue> {
        let group=self.group.as_mut().ok_or_else(||rejected(()))?;
        if group.pending_commit().is_some() || group.pending_proposals().next().is_some() {return Err(rejected(()));}
        group.set_aad(aad.to_vec());
        let bundle=group.self_update(&self.provider,&self.signer,LeafNodeParameters::default()).map_err(rejected)?;
        if bundle.welcome().is_some() {return Err(rejected(()));}
        bundle.commit().tls_serialize_detached().map_err(rejected)
    }
    pub(crate) fn merge_update_inner(&mut self) -> Result<(),JsValue> {
        let group=self.group.as_mut().ok_or_else(||rejected(()))?;
        let commit=group.pending_commit().ok_or_else(||rejected(()))?;
        if commit.queued_proposals().next().is_some() {return Err(rejected(()));}
        group.merge_pending_commit(&self.provider).map_err(rejected)
    }
    pub(crate) fn peer_update_inner(&mut self,bytes:&[u8],actor:&str,key:&[u8],aad:&[u8])->Result<(),JsValue> {
        bounded(bytes,MAX_WIRE)?;
        let expected=expected(actor,key)?;
        let message=MlsMessageIn::tls_deserialize_exact_bytes(bytes).map_err(rejected)?.try_into_protocol_message().map_err(rejected)?;
        let group=self.group.as_mut().ok_or_else(||rejected(()))?;
        if group.pending_commit().is_some() {return Err(rejected(()));}
        let processed=group.process_message(&self.provider,message).map_err(rejected)?;
        let Sender::Member(index)=processed.sender() else {return Err(rejected(()));};
        let member=group.members().find(|m|m.index==*index).ok_or_else(||rejected(()))?;
        if processed.credential()!=&expected.credential || member.credential!=expected.credential || member.signature_key!=key
            || processed.aad()!=aad {return Err(rejected(()));}
        let ProcessedMessageContent::StagedCommitMessage(commit)=processed.into_content() else {return Err(rejected(()));};
        // Only a path rekey of the fixed pair. All membership/PSK/context and
        // other proposals require a separate application authorization contract.
        if commit.queued_proposals().next().is_some() {return Err(rejected(()));}
        group.merge_staged_commit(&self.provider,*commit).map_err(rejected)
    }
}
