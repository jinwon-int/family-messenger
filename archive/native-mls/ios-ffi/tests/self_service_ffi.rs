//! #366 3g: 셀프서비스 FFI 표면이 공용 벡터 `archive/native-mls/tests/fixtures/self-service-vectors.json` 을 host-core 와 같게
//! 판정하는지 본다. Android `core/SelfService` 는 같은 함수를 JNA 로 부른다(`SelfServiceVectorsTest`).
use family_mls_ios_ffi::{
    self_service_actor_has_registrar, self_service_can_approve, self_service_candidates_for, self_service_constants,
    self_service_enroll_mode, self_service_is_active, self_service_is_registrar, self_service_is_sibling, self_service_next_roles,
    self_service_roles_actions, self_service_sibling_invite_rooms, MlsCandidate, MlsEnrollMode, MlsInviteRoom, MlsMe, MlsMeDevice,
};
use serde_json::Value;

fn vectors() -> Value {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/fixtures/self-service-vectors.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("vectors")).expect("json")
}

fn s(v: &Value) -> String {
    v.as_str().unwrap().to_owned()
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array().unwrap().iter().map(s).collect()
}

fn device(v: &Value) -> MlsMeDevice {
    MlsMeDevice {
        device_id: s(&v["device_id"]),
        actor: s(&v["actor"]),
        fingerprint: s(&v["fingerprint"]),
        status: s(&v["status"]),
        acceptance: s(&v["acceptance"]),
        roles: strings(&v["roles"]),
    }
}

fn me(doc: &Value, case: &Value) -> Option<MlsMe> {
    case["me"].as_str().map(|k| {
        let m = &doc["mes"][k];
        MlsMe {
            subject: s(&m["subject"]),
            policy_revision: m["policy_revision"].as_u64(),
            devices: m["devices"].as_array().unwrap().iter().map(device).collect(),
        }
    })
}

fn cases<'a>(doc: &'a Value, key: &str) -> &'a Vec<Value> {
    let v = doc[key].as_array().unwrap();
    assert!(!v.is_empty(), "{key}");
    v
}

#[test]
fn constants_match_the_vectors() {
    let c = &vectors()["constants"];
    let k = self_service_constants();
    assert_eq!(c["role_registrar"], k.role_registrar.as_str());
    assert_eq!(c["status_active"], k.status_active.as_str());
    assert_eq!(c["sibling_invite_ttl_ms"], k.sibling_invite_ttl_ms);
    assert_eq!(c["sibling_lobby_recheck_ms"], k.sibling_lobby_recheck_ms);
    assert_eq!(c["candidate_repost_margin_ms"], k.candidate_repost_margin_ms);
    assert_eq!(c["candidate_ttl_seconds"], k.candidate_ttl_seconds);
}

#[test]
fn decisions_match_the_shared_vectors() {
    let doc = vectors();
    for c in cases(&doc, "actor_has_registrar") {
        assert_eq!(self_service_actor_has_registrar(me(&doc, c), s(&c["actor"])), c["expect"], "{}", c["name"]);
    }
    for c in cases(&doc, "can_approve") {
        assert_eq!(self_service_can_approve(me(&doc, c), s(&c["device"])), c["expect"], "{}", c["name"]);
    }
    for c in cases(&doc, "is_sibling") {
        let got = self_service_is_sibling(c["from"].as_str().map(str::to_owned), me(&doc, c), c["actor"].as_str().map(str::to_owned), s(&c["device"]));
        assert_eq!(got, c["expect"], "{}", c["name"]);
    }
    for c in cases(&doc, "candidates_for") {
        let list: Vec<MlsCandidate> = c["candidates"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| MlsCandidate {
                device_id: s(&r["device_id"]),
                actor: s(&r["actor"]),
                subject: s(&r["subject"]),
                signing_key: s(&r["signing_key"]),
                fingerprint: s(&r["fingerprint"]),
                created_at: r["created_at"].as_i64().unwrap(),
                expires_at: r["expires_at"].as_i64().unwrap(),
            })
            .collect();
        let got: Vec<String> = self_service_candidates_for(list, s(&c["actor"])).into_iter().map(|c| c.device_id).collect();
        assert_eq!(got, strings(&c["expect"]), "{}", c["name"]);
    }
    for c in cases(&doc, "next_roles") {
        assert_eq!(self_service_next_roles(strings(&c["roles"]), c["grant"].as_bool().unwrap()), strings(&c["expect"]), "{c}");
    }
    for c in cases(&doc, "roles_actions") {
        let v = self_service_roles_actions(me(&doc, c), s(&c["device"]));
        let e = &c["expect"];
        assert_eq!(v.can_sign, e["can_sign"], "{}", c["name"]);
        assert_eq!(v.actor.as_deref(), e["actor"].as_str(), "{}", c["name"]);
        let rows: Vec<Value> = v
            .devices
            .iter()
            .map(|d| {
                serde_json::json!({"device_id": d.device_id, "registrar": d.registrar, "is_self": d.is_self,
                    "grant": d.grant, "release": d.release, "last_registrar": d.last_registrar})
            })
            .collect();
        assert_eq!(Value::Array(rows), e["devices"], "{}", c["name"]);
    }
    for c in cases(&doc, "sibling_invite_rooms") {
        let rooms: Vec<MlsInviteRoom> = c["rooms"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| MlsInviteRoom {
                room: s(&r["room"]),
                joined: r["joined"].as_bool().unwrap(),
                halted: r["halted"].as_bool().unwrap(),
                pending: r["pending"].as_bool().unwrap(),
                roster: r["roster"].as_array().map(|_| strings(&r["roster"])),
            })
            .collect();
        assert_eq!(self_service_sibling_invite_rooms(rooms, c["target"].as_str().map(str::to_owned)), strings(&c["expect"]), "{}", c["name"]);
    }
    for c in cases(&doc, "enroll_mode") {
        let got = match self_service_enroll_mode(c["status"].as_u64().unwrap() as u16, s(&c["code"])) {
            MlsEnrollMode::Sibling => "sibling",
            MlsEnrollMode::IdTaken => "id-taken",
            MlsEnrollMode::Operator => "operator",
        };
        assert_eq!(got, c["expect"], "{c}");
    }
}

#[test]
fn registrar_and_active_follow_the_record() {
    let doc = vectors();
    let rec = device(&doc["mes"]["registrar_and_revoked"]["devices"][0]);
    assert!(self_service_is_registrar(rec.clone()) && self_service_is_active(rec));
    let revoked = device(&doc["mes"]["registrar_and_revoked"]["devices"][1]);
    assert!(!self_service_is_registrar(revoked.clone()) && !self_service_is_active(revoked));
}
