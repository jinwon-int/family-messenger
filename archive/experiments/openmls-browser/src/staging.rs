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
        || state.public_key.len() != 32 || !valid_identity(identity) {
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
        "remove" => device.remove_member_inner(input)?,
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
/// 신뢰 거부 사유. JsValue를 생성하지 않아 호스트 단위 테스트에서도 검증 가능하다.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TrustRejection {
    /// 피어 식별자/키 모양 불량 또는 자기 키.
    MalformedPeer,
    /// 그룹 없음/비활성 등 상태 자체가 신뢰 불가.
    InactiveGroup,
    /// 미확인 멤버 포함 또는 own/피어 매칭 실패.
    UnverifiedMembers,
    /// 그룹이 없는데 1:1 페어 경로가 요청됨.
    PairRequired,
}

fn trusted_members_check(device: &Device, peer: &str, key: &[u8], require_pair: bool) -> Result<(), TrustRejection> {
    if !valid_identity(peer) || key.len()!=32 || key==device.signer.public() {return Err(TrustRejection::MalformedPeer);}
    let expected: Credential=BasicCredential::new(peer.as_bytes().to_vec()).into();
    if let Some(group)=&device.group {
        if !group.is_active(){return Err(TrustRejection::InactiveGroup);}
        let members: Vec<_>=group.members().collect();
        if members.is_empty() || (require_pair && members.len()<2){return Err(TrustRejection::UnverifiedMembers);}
        let own=members.iter().filter(|m|m.credential==device.credential.credential && m.signature_key==device.signer.public()).count();
        let peers=members.iter().filter(|m|m.credential==expected && m.signature_key==key).count();
        // require_pair=false: own-only 그룹(peers==0, create 직후)도 허용하되 미확인 멤버는 거부.
        // require_pair=true: 정확한 1:1 페어만 허용(encrypt/decrypt 및 staged_control_apply 경로).
        if own!=1 || members.len()-own-peers!=0 || (require_pair && peers!=1) {return Err(TrustRejection::UnverifiedMembers);}
    } else if require_pair {return Err(TrustRejection::PairRequired);}
    Ok(())
}

fn trusted_members(device: &Device, peer: &str, key: &[u8], require_pair: bool) -> Result<(), JsValue> {
    trusted_members_check(device, peer, key, require_pair).map_err(rejected)
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
/// Roles are chosen by the caller per operation: the committer stages/merges its own
/// update, the other member applies it. No identity label is privileged.
#[wasm_bindgen]
pub fn staged_control_apply(bytes:&[u8],identity:&str,method:&str,input:&[u8],peer:&str,key:&[u8],aad:&[u8])->Result<Transition,JsValue> {
    if input.len()>MAX_WIRE || aad.is_empty() || aad.len()>2048 {return Err(rejected(()));}
    let mut device=load(bytes,identity)?;
    trusted_members(&device,peer,key,true)?;
    let before=device.group.as_ref().ok_or_else(||rejected(()))?.epoch().as_u64();
    let output=match method {
        "update" if input.is_empty()=>device.stage_update_inner(aad)?,
        "merge_update" if input.is_empty()=>{device.merge_update_inner()?;vec![]},
        "peer_update"=>{device.peer_update_inner(input,peer,key,aad)?;vec![]},
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

#[cfg(test)]
mod tests {
    use super::*;

    fn key32(byte: u8) -> Vec<u8> { vec![byte; 32] }

    /// CI 'Durable trusted state' 스모크 회귀 재발 방지: create 직후 own-only
    /// 그룹(peers==0)은 require_pair=false 신뢰 검사를 통과해야 하고,
    /// require_pair=true 경로는 계속 거부해야 한다.
    #[test]
    fn own_only_group_is_trusted_without_pair() {
        let mut device = Device::new("alice").expect("device");
        device.create_inner().expect("create");
        let state = save(&device, "alice").expect("save");
        let restored = load(&state, "alice").expect("load");
        trusted_members_check(&restored, "bob", &key32(7), false).expect("own-only group trusted");
        assert_eq!(trusted_members_check(&restored, "bob", &key32(7), true), Err(TrustRejection::UnverifiedMembers),
            "own-only group must still fail the strict pair check");
    }

    /// 정확한 1:1 페어는 양방향 require_pair=true를 통과하고, 저장/복원
    /// 라운드트립 후에도 동일 판정을 유지한다.
    #[test]
    fn exact_pair_passes_strict_check() {
        let mut alice = Device::new("alice").expect("device");
        let mut bob = Device::new("bob").expect("device");
        alice.create_inner().expect("create");
        let bob_kp = bob.key_package_inner().expect("bob key package");
        let welcome = alice.invite_inner(&bob_kp).expect("invite");
        bob.join_inner(&welcome).expect("join");
        let bob_key = bob.signer.public().to_vec();
        let alice_key = alice.signer.public().to_vec();
        trusted_members_check(&alice, "bob", &bob_key, true).expect("alice strict pair");
        trusted_members_check(&bob, "alice", &alice_key, true).expect("bob strict pair");
        let state = save(&alice, "alice").expect("save");
        let restored = load(&state, "alice").expect("load");
        trusted_members_check(&restored, "bob", &bob_key, true).expect("restored strict pair");
    }

    /// 미확인 멤버가 섞인 그룹은 페어 키가 정확해도 거부된다(수정의
    /// `members.len()-own-peers!=0` 절). 키가 어긋나도 거부된다.
    #[test]
    fn unverified_extra_member_is_rejected() {
        let mut alice = Device::new("alice").expect("device");
        let bob = Device::new("bob").expect("device");
        let charlie = Device::new("charlie").expect("device");
        alice.create_inner().expect("create");
        let bob_kp = bob.key_package_inner().expect("bob key package");
        alice.invite_inner(&bob_kp).expect("invite bob");
        let charlie_kp = charlie.key_package_inner().expect("charlie key package");
        alice.invite_inner(&charlie_kp).expect("invite charlie");
        let bob_key = bob.signer.public().to_vec();
        assert_eq!(trusted_members_check(&alice, "bob", &bob_key, false), Err(TrustRejection::UnverifiedMembers),
            "unverified third member must be rejected");
        assert_eq!(trusted_members_check(&alice, "bob", &bob_key, true), Err(TrustRejection::UnverifiedMembers));
        assert_eq!(trusted_members_check(&alice, "bob", &key32(9), false), Err(TrustRejection::UnverifiedMembers),
            "mismatched peer key must be rejected");
    }

    /// 피어 식별자/키의 조기 검증(빈 라벨, 잘못된 모양, 짧은 키, 자기 키)은
    /// 그룹 상태와 무관하게 거부된다.
    #[test]
    fn malformed_trust_inputs_are_rejected() {
        let mut alice = Device::new("alice").expect("device");
        alice.create_inner().expect("create");
        let own = alice.signer.public().to_vec();
        assert_eq!(trusted_members_check(&alice, "", &key32(1), false), Err(TrustRejection::MalformedPeer));
        assert_eq!(trusted_members_check(&alice, "bad id!", &key32(1), false), Err(TrustRejection::MalformedPeer));
        assert_eq!(trusted_members_check(&alice, "bob", &[1u8; 31], false), Err(TrustRejection::MalformedPeer));
        assert_eq!(trusted_members_check(&alice, "bob", &own, false), Err(TrustRejection::MalformedPeer));
    }
}
