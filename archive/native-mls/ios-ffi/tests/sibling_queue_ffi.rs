//! #366 3h-a: 형제 초대 대기열·재탐색 FFI 표면이 공용 벡터 `archive/native-mls/tests/fixtures/sibling-queue-vectors.json` 을
//! host-core 와 같게 판정하는지 본다. Android `core/SelfService`·`SiblingRescan` 은 같은 함수를 JNA 로 부른다(`SiblingQueueVectorsTest`).
use family_mls_ios_ffi::{
    sibling_invite_budget, sibling_queue_decode, sibling_queue_encode, sibling_queue_enqueue, sibling_queue_next_entry,
    sibling_queue_split, sibling_rescan_constants, sibling_rescan_decode_state, sibling_rescan_due, sibling_rescan_encode_state,
    sibling_rescan_siblings, sibling_rescan_turn, MlsMe, MlsMeDevice, MlsRescanExcluded, MlsRescanPending, MlsRescanRoom,
    MlsRescanState, MlsSiblingInvite,
};
use serde_json::{json, Value};

fn vectors() -> Value {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/fixtures/sibling-queue-vectors.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("vectors")).expect("json")
}

fn cases<'a>(v: &'a Value, key: &str) -> &'a Vec<Value> {
    let c = v[key].as_array().unwrap_or_else(|| panic!("{key} missing"));
    assert!(!c.is_empty(), "{key} empty");
    c
}

fn s(v: &Value) -> String {
    v.as_str().unwrap().to_owned()
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array().unwrap().iter().map(s).collect()
}

fn entry(v: &Value) -> MlsSiblingInvite {
    MlsSiblingInvite {
        target: s(&v["target"]),
        rooms: strings(&v["rooms"]),
        since: v["since"].as_i64().unwrap(),
        progress: v["progress"].as_i64(),
        recheck_at: v["recheck_at"].as_i64(),
        origin: v["origin"].as_str().map(str::to_owned),
    }
}

fn entry_json(e: &MlsSiblingInvite) -> Value {
    json!({"target": e.target, "rooms": e.rooms, "since": e.since, "progress": e.progress, "recheck_at": e.recheck_at, "origin": e.origin})
}

fn queue(v: &Value) -> Vec<MlsSiblingInvite> {
    v.as_array().unwrap().iter().map(entry).collect()
}

fn state(v: &Value) -> MlsRescanState {
    MlsRescanState {
        last: v["last"].as_i64(),
        pending: v["pending"].as_array().unwrap().iter().map(|p| MlsRescanPending { key: s(&p["key"]), seen: p["seen"].as_i64().unwrap() }).collect(),
    }
}

fn state_json(st: &MlsRescanState) -> Value {
    json!({"last": st.last, "pending": st.pending.iter().map(|p| json!({"key": p.key, "seen": p.seen})).collect::<Vec<_>>()})
}

fn me(doc: &Value, case: &Value) -> Option<MlsMe> {
    case["me"].as_str().map(|k| {
        let m = &doc["mes"][k];
        MlsMe {
            subject: s(&m["subject"]),
            policy_revision: m["policy_revision"].as_u64(),
            devices: m["devices"]
                .as_array()
                .unwrap()
                .iter()
                .map(|d| MlsMeDevice {
                    device_id: s(&d["device_id"]),
                    actor: s(&d["actor"]),
                    fingerprint: s(&d["fingerprint"]),
                    status: s(&d["status"]),
                    acceptance: s(&d["acceptance"]),
                    roles: strings(&d["roles"]),
                })
                .collect(),
        }
    })
}

#[test]
fn constants() {
    let v = vectors();
    let c = sibling_rescan_constants();
    assert_eq!(v["constants"]["rescan_interval_ms"], c.interval_ms);
    assert_eq!(v["constants"]["rescan_deferral_ms"], c.deferral_ms);
    assert_eq!(v["constants"]["rescan_origin"], c.origin);
}

#[test]
fn queue_rules_and_text() {
    let v = vectors();
    for c in cases(&v, "enqueue") {
        let got = sibling_queue_enqueue(queue(&c["queue"]), s(&c["target"]), strings(&c["rooms"]), c["now"].as_i64().unwrap(), c["origin"].as_str().map(str::to_owned));
        assert_eq!(Value::Array(got.iter().map(entry_json).collect()), c["expect"], "{}", c["name"]);
    }
    for c in cases(&v, "split") {
        let r = sibling_queue_split(queue(&c["queue"]), c["now"].as_i64().unwrap(), c["ttl"].as_i64().unwrap());
        let t = |q: &[MlsSiblingInvite]| q.iter().map(|e| e.target.clone()).collect::<Vec<_>>();
        assert_eq!(json!({"live": t(&r.live), "expired": t(&r.expired)}), c["expect"], "{}", c["name"]);
    }
    for c in cases(&v, "budget") {
        let want = c["expect"].as_i64().map_or(i32::MAX, |n| n as i32);
        assert_eq!(sibling_invite_budget(c["live"].as_i64().map(|n| n as i32)), want, "{}", c["name"]);
    }
    for c in cases(&v, "next_entry") {
        let got = sibling_queue_next_entry(entry(&c["entry"]), strings(&c["remaining"]), c["now"].as_i64().unwrap(), c["progressed"].as_bool().unwrap(), c["starved"].as_bool().unwrap());
        assert_eq!(got.as_ref().map_or(Value::Null, entry_json), c["expect"], "{}", c["name"]);
    }
    for c in cases(&v, "queue_text_decode") {
        let got = sibling_queue_decode(c["text"].as_str().map(str::to_owned));
        assert_eq!(Value::Array(got.iter().map(entry_json).collect()), c["expect"], "{}", c["name"]);
    }
    for c in cases(&v, "queue_text_encode") {
        assert_eq!(sibling_queue_encode(queue(&c["queue"])), s(&c["expect"]), "{}", c["name"]);
    }
}

#[test]
fn rescan_rules_and_text() {
    let v = vectors();
    for c in cases(&v, "rescan_siblings") {
        assert_eq!(sibling_rescan_siblings(me(&v, c), s(&c["device"])), strings(&c["expect"]), "{}", c["name"]);
    }
    for c in cases(&v, "rescan_due") {
        assert_eq!(sibling_rescan_due(state(&c["state"]), c["now"].as_i64().unwrap()), c["expect"], "{}", c["name"]);
    }
    for c in cases(&v, "rescan_turn") {
        let rooms = c["rooms"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| MlsRescanRoom {
                room: s(&r["room"]),
                joined: r["joined"].as_bool().unwrap(),
                halted: r["halted"].as_bool().unwrap(),
                pending: r["pending"].as_bool().unwrap(),
                roster: r["roster"].as_array().map(|_| strings(&r["roster"])),
                synced: r["synced"].as_bool().unwrap(),
            })
            .collect();
        let excluded = c["excluded"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, x)| MlsRescanExcluded { target: k.clone(), rooms: x.as_array().map(|_| strings(x)) })
            .collect();
        let t = sibling_rescan_turn(rooms, s(&c["device"]), strings(&c["siblings"]), excluded, state(&c["state"]), c["now"].as_i64().unwrap());
        let got = json!({"ready": t.ready,
            "enqueue": t.enqueue.iter().map(|e| json!({"target": e.target, "rooms": e.rooms})).collect::<Vec<_>>(),
            "state": state_json(&t.state)});
        assert_eq!(got, c["expect"], "{}", c["name"]);
    }
    for c in cases(&v, "rescan_state_text_decode") {
        assert_eq!(state_json(&sibling_rescan_decode_state(c["text"].as_str().map(str::to_owned))), c["expect"], "{}", c["name"]);
    }
    for c in cases(&v, "rescan_state_text_encode") {
        assert_eq!(sibling_rescan_encode_state(state(&c["state"])), s(&c["expect"]), "{}", c["name"]);
    }
}
