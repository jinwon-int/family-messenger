//! Isolated candidate construction, NOT enrollment, authorization or persistence.
use super::*;

/// The caller must authenticate and bind the whole source before this operation.
/// Only the signer enters the fresh provider; no old group/ratchet/KeyPackage is
/// copied. Returned private bytes must remain in a trusted worker and must not
/// be used until a separately qualified encrypted custody commit completes.
#[wasm_bindgen]
pub fn staged_identity_context(
    bytes: &[u8], identity: &str, own_key: &[u8], source_group: &[u8],
    peer: &str, peer_key: &[u8],
) -> Result<Vec<u8>, JsValue> {
    if !["alice", "bob"].contains(&identity) || peer == identity
        || own_key.len() != 32 || source_group.len() < 16 || source_group.len() > 128 {
        return Err(rejected(()));
    }
    let source = load(bytes, identity)?;
    trusted_members(&source, peer, peer_key, true)?;
    let group = source.group.as_ref().ok_or_else(|| rejected(()))?;
    if source.signer.public() != own_key
        || source.signer.signature_scheme() != SUITE.signature_algorithm()
        || group.group_id().as_slice() != source_group {
        return Err(rejected(()));
    }
    let provider = OpenMlsRustCrypto::default();
    source.signer.store(provider.storage()).map_err(rejected)?;
    let signer = SignatureKeyPair::read(provider.storage(), own_key, SUITE.signature_algorithm())
        .ok_or_else(|| rejected(()))?;
    if signer.public() != own_key || provider.storage().values.read().map_err(rejected)?.len() != 1 {
        return Err(rejected(()));
    }
    let target = Device {
        provider, signer, credential: source.credential, group: None, retired: false,
    };
    let state = save(&target, identity)?;
    let restored = load(&state, identity)?;
    if restored.group.is_some() || restored.signer.public() != own_key {
        return Err(rejected(()));
    }
    Ok(state)
}

/// Domain-separated signature for an explicit short-lived successor lease.
/// A signature is released by the worker only after its protected local commit.
#[wasm_bindgen]
pub fn staged_lease_signature(bytes:&[u8],identity:&str,peer:&str,key:&[u8],digest:&[u8])->Result<Vec<u8>,JsValue>{
    use openmls_traits::signatures::Signer;
    if digest.len()!=32{return Err(rejected(()));}
    let device=load(bytes,identity)?;trusted_members(&device,peer,key,true)?;
    if device.group.as_ref().ok_or_else(||rejected(()))?.epoch().as_u64()!=1{return Err(rejected(()));}
    let mut message=b"family-successor-lease-v1\0".to_vec();message.extend_from_slice(digest);
    device.signer.sign(&message).map_err(rejected)
}
