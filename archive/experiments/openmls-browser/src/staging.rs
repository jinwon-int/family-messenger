//! Full provider/group staging. Secret snapshots stay inside the synthetic worker.
use super::*;
use serde::{Deserialize, Serialize as SerdeSerialize};
use std::collections::HashMap;

const MAX_STATE: usize = 1024 * 1024;
const MAX_ENTRIES: usize = 512;

#[derive(SerdeSerialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Snapshot {
    version: u32,
    identity: String,
    public_key: Vec<u8>,
    group_id: Option<Vec<u8>>,
    entries: Vec<(Vec<u8>, Vec<u8>)>,
}

fn save(device: &Device, identity: &str) -> Result<Vec<u8>, JsValue> {
    let values = device.provider.storage().values.read().map_err(rejected)?;
    if values.len() > MAX_ENTRIES { return Err(rejected(())); }
    let mut entries: Vec<_> = values.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    let state = Snapshot {
        version: 1, identity: identity.into(), public_key: device.signer.public().into(),
        group_id: device.group.as_ref().map(|g| g.group_id().as_slice().to_vec()), entries,
    };
    let bytes = serde_json::to_vec(&state).map_err(rejected)?;
    bounded(&bytes, MAX_STATE)?;
    Ok(bytes)
}

fn load(bytes: &[u8], identity: &str) -> Result<Device, JsValue> {
    bounded(bytes, MAX_STATE)?;
    let state: Snapshot = serde_json::from_slice(bytes).map_err(rejected)?;
    if state.version != 1 || state.identity != identity || state.entries.len() > MAX_ENTRIES
        || state.public_key.len() != 32
        || !["alice", "bob", "outsider", "alice-second"].contains(&identity) {
        return Err(rejected(()));
    }
    let provider = OpenMlsRustCrypto::default();
    let mut values = HashMap::new();
    for (key, value) in state.entries {
        if key.is_empty() || key.len() > MAX_WIRE || value.is_empty() || value.len() > MAX_STATE
            || values.insert(key, value).is_some() { return Err(rejected(())); }
    }
    *provider.storage().values.write().map_err(rejected)? = values;
    let signer = SignatureKeyPair::read(provider.storage(), &state.public_key, SUITE.signature_algorithm())
        .ok_or_else(|| rejected(()))?;
    if signer.public() != state.public_key { return Err(rejected(())); }
    let group = match state.group_id {
        Some(id) => {
            bounded(&id, 128)?;
            Some(MlsGroup::load(provider.storage(), &GroupId::from_slice(&id)).map_err(rejected)?
                .ok_or_else(|| rejected(()))?)
        },
        None => None,
    };
    let credential = CredentialWithKey {
        credential: BasicCredential::new(identity.as_bytes().to_vec()).into(),
        signature_key: state.public_key.into(),
    };
    if let Some(group) = &group {
        if group.is_active() {
            let leaf = group.own_leaf().ok_or_else(|| rejected(()))?;
            if leaf.credential() != &credential.credential || leaf.signature_key() != &credential.signature_key {
                return Err(rejected(()));
            }
        }
    }
    Ok(Device { provider, signer, credential, group, retired: false })
}

/// A candidate only. The caller must atomically persist state and output before use.
#[wasm_bindgen]
pub struct Transition { state: Vec<u8>, output: Vec<u8>, epoch: String }
#[wasm_bindgen]
impl Transition {
    pub fn state(&self) -> Vec<u8> { self.state.clone() }
    pub fn output(&self) -> Vec<u8> { self.output.clone() }
    pub fn epoch(&self) -> String { self.epoch.clone() }
}

#[wasm_bindgen]
pub fn staged_init(identity: &str) -> Result<Vec<u8>, JsValue> {
    let device = Device::new(identity)?;
    save(&device, identity)
}

/// Reconstruct all mutable state in an isolated provider for each operation.
/// Rejection discards the candidate, including consumed Welcome/ratchet keys.
#[wasm_bindgen]
pub fn staged_apply(bytes: &[u8], identity: &str, method: &str, input: &[u8]) -> Result<Transition, JsValue> {
    if input.len() > MAX_WIRE { return Err(rejected(())); }
    let mut device = load(bytes, identity)?;
    let output = match method {
        "key_package" if input.is_empty() => device.key_package_inner()?,
        "create" if input.is_empty() => { device.create_inner()?; vec![] },
        "invite" => device.invite_inner(input)?,
        "join" => { device.join_inner(input)?; vec![] },
        "encrypt" => device.encrypt_inner(input)?,
        "decrypt" => device.decrypt_inner(input)?,
        "remove" if input.is_empty() => device.remove_invitee_inner()?,
        "commit" => { device.apply_commit_inner(input)?; vec![] },
        _ => return Err(rejected(())),
    };
    bounded(&output, MAX_WIRE).or_else(|e| if output.is_empty() { Ok(()) } else { Err(e) })?;
    // Roundtrip the entire provider through supported load before releasing a candidate.
    let state = save(&device, identity)?;
    let _ = load(&state, identity)?;
    let epoch = epoch_of(&device);
    Ok(Transition { state, output, epoch })
}

fn epoch_of(device: &Device) -> String {
    device.group.as_ref().map(|g| g.epoch().as_u64().to_string()).unwrap_or_else(|| "none".into())
}
#[wasm_bindgen]
pub fn staged_epoch(bytes: &[u8], identity: &str) -> Result<String, JsValue> {
    Ok(epoch_of(&load(bytes, identity)?))
}

/// Accidental-corruption checksum only, not authentication or rollback protection.
/// Reuses the vetted provider synchronously so IndexedDB keeps its transaction open.
#[wasm_bindgen]
pub fn staged_checksum(bytes: &[u8]) -> Result<Vec<u8>, JsValue> {
    bounded(bytes, 5 * 1024 * 1024)?;
    OpenMlsRustCrypto::default().crypto().hash(HashType::Sha2_256, bytes).map_err(rejected)
}

#[wasm_bindgen]
pub fn staged_public_key(bytes: &[u8], identity: &str) -> Result<Vec<u8>, JsValue> {
    Ok(load(bytes, identity)?.signer.public().to_vec())
}
#[wasm_bindgen]
pub fn staged_group_id(bytes: &[u8], identity: &str) -> Result<Vec<u8>, JsValue> {
    Ok(load(bytes, identity)?.group.as_ref().map(|g|g.group_id().as_slice().to_vec()).unwrap_or_default())
}
fn trusted_members(device: &Device, peer: &str, key: &[u8], require_pair: bool) -> Result<(), JsValue> {
    if !["alice", "bob"].contains(&peer) || key.len()!=32 || key==device.signer.public() {return Err(rejected(()));}
    let expected: Credential=BasicCredential::new(peer.as_bytes().to_vec()).into();
    if let Some(group)=&device.group {
        if !group.is_active(){return Err(rejected(()));}
        let members: Vec<_>=group.members().collect();
        if members.is_empty() || members.len()>2 || (require_pair && members.len()!=2){return Err(rejected(()));}
        let own=members.iter().filter(|m|m.credential==device.credential.credential && m.signature_key==device.signer.public()).count();
        let peers=members.iter().filter(|m|m.credential==expected && m.signature_key==key).count();
        if own!=1 || own+peers!=members.len(){return Err(rejected(()));}
    } else if require_pair {return Err(rejected(()));}
    Ok(())
}
#[wasm_bindgen]
pub fn staged_check_trust(bytes: &[u8], identity: &str, peer: &str, key: &[u8]) -> Result<(), JsValue> {
    trusted_members(&load(bytes,identity)?,peer,key,false)
}
#[wasm_bindgen]
pub fn staged_trusted_apply(bytes: &[u8], identity: &str, method: &str, input: &[u8], peer: &str, key: &[u8]) -> Result<Transition, JsValue> {
    if input.len()>MAX_WIRE {return Err(rejected(()));}
    let mut device=load(bytes,identity)?;
    trusted_members(&device,peer,key,method=="encrypt"||method=="decrypt"||method=="decrypt_peer")?;
    let output=match method {
        "key_package" if input.is_empty()=>device.key_package_inner()?,
        "create" if input.is_empty()=>{device.create_inner()?;vec![]},
        "invite"=>device.invite_trusted(input,peer,key)?,
        "join"=>{device.join_trusted(input,peer,key)?;vec![]},
        "encrypt"=>device.encrypt_inner(input)?,
        "decrypt"=>device.decrypt_inner(input)?,
        "decrypt_peer"=>device.decrypt_peer_inner(input,peer,key)?,
        _=>return Err(rejected(())),
    };
    if output.len()>MAX_WIRE{return Err(rejected(()));}
    trusted_members(&device,peer,key,false)?;
    let state=save(&device,identity)?;
    trusted_members(&load(&state,identity)?,peer,key,false)?;
    Ok(Transition{state,output,epoch:epoch_of(&device)})
}

/// Fixed-pair rekey controls; complete candidate state is never released live.
#[wasm_bindgen]
pub fn staged_control_apply(bytes:&[u8],identity:&str,method:&str,input:&[u8],peer:&str,key:&[u8],aad:&[u8])->Result<Transition,JsValue> {
    if input.len()>MAX_WIRE || aad.is_empty() || aad.len()>2048 {return Err(rejected(()));}
    let mut device=load(bytes,identity)?;
    trusted_members(&device,peer,key,true)?;
    let before=device.group.as_ref().ok_or_else(||rejected(()))?.epoch().as_u64();
    let output=match method {
        "update" if identity=="alice" && input.is_empty()=>device.stage_update_inner(aad)?,
        "merge_update" if identity=="alice" && input.is_empty()=>{device.merge_update_inner()?;vec![]},
        "peer_update" if identity=="bob"=>{device.peer_update_inner(input,peer,key,aad)?;vec![]},
        _=>return Err(rejected(())),
    };
    if output.len()>MAX_WIRE {return Err(rejected(()));}
    let group=device.group.as_ref().ok_or_else(||rejected(()))?;
    let expected=if method=="update" {before} else {before.checked_add(1).ok_or_else(||rejected(()))?};
    if group.epoch().as_u64()!=expected || group.pending_commit().is_some()!=(method=="update") {return Err(rejected(()));}
    trusted_members(&device,peer,key,true)?;
    let state=save(&device,identity)?;
    let restored=load(&state,identity)?;
    trusted_members(&restored,peer,key,true)?;
    if restored.group.as_ref().ok_or_else(||rejected(()))?.pending_commit().is_some()!=(method=="update") {return Err(rejected(()));}
    Ok(Transition{state,output,epoch:epoch_of(&device)})
}
#[wasm_bindgen]
pub fn staged_pending_commit(bytes:&[u8],identity:&str)->Result<bool,JsValue> {
    Ok(load(bytes,identity)?.group.as_ref().map(|g|g.pending_commit().is_some()).unwrap_or(false))
}

#[cfg(feature = "identity-context")]
mod identity_context;
