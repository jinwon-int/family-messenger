//! #366 3a 호스트 게이트: `MlsRoom` 이 Rust 로 구현한 호스트 콜백(in-memory 릴레이 + 관찰자) 위에서 봇과 같은
//! 동기화·송신 규칙으로 도는지. 릴레이는 와이어 JSON 만 흉내 내는 순서 매기기(MLS 검증 없음, cas 검사만).
//! 이 파일이 깨지면 "봇·Android 가 한 코드" 라는 2단계의 전제가 깨진 것이다.
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use family_mls_ios_ffi::{
    HttpHeader, HttpResponse, HttpTransport, MlsRoom, RoomError, RoomEvent, RoomObserver, RoomSyncState, SendResult,
};
use native_mls_host::b64;

const BASE: &str = "http://relay.test";

#[derive(Clone)]
struct Row {
    seq: i64,
    device: String,
    client_id: String,
    kind: String,
    epoch: i64,
    bytes: Vec<u8>,
    targets: Vec<String>,
}

#[derive(Default)]
struct RoomRows {
    epoch: i64,
    next_seq: i64,
    rows: Vec<Row>,
}

/// v2 릴레이의 events 라우트만: GET 페이지(Welcome 은 대상에게만) · POST(cas_mismatch · client_id dedup).
struct Relay {
    rooms: Mutex<HashMap<String, RoomRows>>,
    trace: Arc<Mutex<Vec<String>>>,
    down: AtomicBool,
}

impl Relay {
    fn new(trace: Arc<Mutex<Vec<String>>>) -> Arc<Relay> {
        Arc::new(Relay { rooms: Mutex::new(HashMap::new()), trace, down: AtomicBool::new(false) })
    }
    /// 다른 기기가 commit 을 올린 것처럼 epoch 만 올린다(cas_mismatch 유발).
    fn bump_epoch(&self, room: &str) {
        self.rooms.lock().unwrap().entry(room.into()).or_default().epoch += 1;
    }
    /// `before` 앞의 seq 를 정리한다(#268 history gap 유발).
    fn prune_before(&self, room: &str, before: i64) {
        self.rooms.lock().unwrap().entry(room.into()).or_default().rows.retain(|r| r.seq >= before);
    }
    fn rows(&self, room: &str) -> Vec<Row> {
        self.rooms.lock().unwrap().get(room).map(|r| r.rows.clone()).unwrap_or_default()
    }

    fn respond(status: u16, body: serde_json::Value) -> Result<HttpResponse, RoomError> {
        Ok(HttpResponse { status, body: serde_json::to_vec(&body).unwrap() })
    }

    fn get(&self, room: &str, query: &str) -> Result<HttpResponse, RoomError> {
        let params: HashMap<&str, &str> = query.split('&').filter_map(|kv| kv.split_once('=')).collect();
        let device = params["device"];
        let after: i64 = params["after"].parse().unwrap();
        self.trace.lock().unwrap().push(format!("GET {device} after={after} ack={}", params.get("ack").copied().unwrap_or("-")));
        let rooms = self.rooms.lock().unwrap();
        let Some(state) = rooms.get(room) else {
            return Self::respond(404, serde_json::json!({ "error": "no_such_room" }));
        };
        let events: Vec<serde_json::Value> = state
            .rows
            .iter()
            .filter(|r| r.seq > after && (r.kind != "welcome" || r.targets.iter().any(|t| t == device)))
            .map(|r| serde_json::json!({
                "seq": r.seq, "device": r.device, "client_id": r.client_id, "kind": r.kind, "epoch": r.epoch,
                "bytes": b64::encode(&r.bytes), "sha256": "", "created_at": 0,
            }))
            .collect();
        let first_seq = state.rows.first().map(|r| r.seq).unwrap_or(0);
        Self::respond(200, serde_json::json!({ "epoch": state.epoch, "revision": 0, "events": events, "first_seq": first_seq }))
    }

    fn post(&self, room: &str, body: &[u8]) -> Result<HttpResponse, RoomError> {
        let post: serde_json::Value = serde_json::from_slice(body).expect("event post json");
        let field = |k: &str| post[k].as_str().unwrap_or_default().to_string();
        let (device, client_id, kind) = (field("device"), field("client_id"), field("kind"));
        let epoch = post["epoch"].as_i64().unwrap_or_default();
        self.trace.lock().unwrap().push(format!("POST {kind} {client_id}"));
        let mut rooms = self.rooms.lock().unwrap();
        let state = rooms.entry(room.into()).or_default();
        if let Some(existing) = state.rows.iter().find(|r| r.device == device && r.client_id == client_id) {
            return Self::respond(200, serde_json::json!({ "seq": existing.seq, "epoch": state.epoch, "revision": 0, "duplicate": true }));
        }
        if kind != "welcome" && epoch != state.epoch {
            return Self::respond(409, serde_json::json!({ "error": "cas_mismatch" }));
        }
        state.next_seq += 1;
        let seq = state.next_seq;
        state.rows.push(Row {
            seq, device, client_id, kind: kind.clone(), epoch: state.epoch,
            bytes: b64::decode(post["bytes"].as_str().unwrap_or_default()).expect("bytes b64"),
            targets: post["targets"].as_array().map(|t| t.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default(),
        });
        if kind == "commit" {
            state.epoch += 1;
        }
        Self::respond(200, serde_json::json!({ "seq": seq, "epoch": state.epoch, "revision": 0, "duplicate": false }))
    }
}

impl HttpTransport for Relay {
    fn send(&self, method: String, url: String, headers: Vec<HttpHeader>, body: Option<Vec<u8>>) -> Result<HttpResponse, RoomError> {
        if self.down.load(Ordering::SeqCst) {
            return Err(RoomError::Host { reason: "connection refused (test)".into() });
        }
        assert!(headers.is_empty(), "no access token configured");
        let path = url.strip_prefix(BASE).expect("url under base");
        let (path, query) = path.split_once('?').unwrap_or((path, ""));
        let room = path.strip_prefix("/v2/rooms/").and_then(|p| p.strip_suffix("/events")).expect("events route");
        match method.as_str() {
            "GET" => self.get(room, query),
            "POST" => self.post(room, &body.unwrap_or_default()),
            other => panic!("unexpected method {other}"),
        }
    }
}

/// 관찰자: 영속·이벤트·메시지·정지를 전부 기록한다.
#[derive(Default)]
struct Observer {
    name: String,
    trace: Arc<Mutex<Vec<String>>>,
    persisted: Mutex<Vec<(Vec<u8>, RoomSyncState)>>,
    events: Mutex<Vec<RoomEvent>>,
    apps: Mutex<Vec<(i64, String, String, Vec<u8>)>>,
    halts: Mutex<Vec<(String, String, RoomSyncState)>>,
}

impl Observer {
    fn new(name: &str, trace: Arc<Mutex<Vec<String>>>) -> Arc<Observer> {
        Arc::new(Observer { name: name.into(), trace, ..Observer::default() })
    }
    fn events(&self) -> Vec<RoomEvent> { self.events.lock().unwrap().clone() }
    fn texts(&self) -> Vec<(i64, String, String)> {
        self.apps.lock().unwrap().iter().map(|(seq, from, _, pt)| (*seq, from.clone(), String::from_utf8_lossy(pt).into_owned())).collect()
    }
    fn last_persisted(&self) -> (Vec<u8>, RoomSyncState) { self.persisted.lock().unwrap().last().cloned().expect("persisted at least once") }
}

impl RoomObserver for Observer {
    fn persist(&self, state: Vec<u8>, sync: RoomSyncState) -> Result<(), RoomError> {
        self.trace.lock().unwrap().push(format!("persist {} cursor={} sends={}", self.name, sync.cursor, sync.sends));
        self.persisted.lock().unwrap().push((state, sync));
        Ok(())
    }
    fn event(&self, event: RoomEvent) { self.events.lock().unwrap().push(event); }
    fn application(&self, seq: i64, sender: String, client_id: String, plaintext: Vec<u8>) -> Result<(), RoomError> {
        self.apps.lock().unwrap().push((seq, sender, client_id, plaintext));
        Ok(())
    }
    fn halted(&self, reason: String, detail: String, sync: RoomSyncState) -> Result<(), RoomError> {
        self.halts.lock().unwrap().push((reason, detail, sync));
        Ok(())
    }
}

struct Harness {
    relay: Arc<Relay>,
    trace: Arc<Mutex<Vec<String>>>,
}

impl Harness {
    fn new() -> Harness {
        let trace = Arc::new(Mutex::new(Vec::new()));
        Harness { relay: Relay::new(trace.clone()), trace }
    }
    fn room(&self, identity: &str) -> (Arc<MlsRoom>, Arc<Observer>) {
        let observer = Observer::new(identity, self.trace.clone());
        let room = MlsRoom::new(identity.into(), "room-a".into(), BASE.into(), self.relay.clone(), observer.clone())
            .unwrap_or_else(|e| panic!("room {identity}: {e}"));
        (room, observer)
    }
    fn trace(&self) -> Vec<String> { self.trace.lock().unwrap().clone() }
}

fn ok<T>(result: Result<T, impl std::fmt::Display>, what: &str) -> T {
    match result {
        Ok(value) => value,
        Err(err) => panic!("{what}: {err}"),
    }
}

/// owner 가 방을 만들고 peer 를 `invite`(로컬 merge) → Welcome 을 올린다 → peer 가 poll 로 join 한다.
fn founded_pair(h: &Harness) -> ((Arc<MlsRoom>, Arc<Observer>), (Arc<MlsRoom>, Arc<Observer>)) {
    let (owner, owner_obs) = h.room("owner-phone");
    let (peer, peer_obs) = h.room("owner-pc");
    ok(peer.poll(), "peer polls before the room exists");
    assert!(peer_obs.events().is_empty(), "404 no_such_room is not an event");
    ok(owner.dispatch("create".into(), Vec::new()), "create");
    let kp = ok(peer.dispatch("key_package".into(), Vec::new()), "peer key package");
    let welcome = ok(owner.dispatch("invite".into(), kp), "invite");
    let posted = ok(owner.post_welcome(welcome, vec!["owner-pc".into()]), "post welcome");
    assert_eq!((posted.seq, posted.duplicate), (1, false));
    ((owner, owner_obs), (peer, peer_obs))
}

#[test]
fn two_rooms_roundtrip_over_the_relay() {
    let h = Harness::new();
    let ((owner, owner_obs), (peer, peer_obs)) = founded_pair(&h);

    let sent = ok(owner.send(b"hello pc".to_vec()), "owner send");
    let SendResult::Sent { client_id, seq, duplicate, .. } = sent else { panic!("expected Sent, got {sent:?}") };
    assert_eq!((seq, duplicate), (2, false));
    assert!(client_id.starts_with("owner-phone-") && client_id.len() == "owner-phone-".len() + 8, "{client_id}");
    assert!(!client_id.contains("-echo-"), "a bot must not mistake app messages for echoes");

    ok(peer.poll(), "peer poll");
    assert_eq!(peer_obs.events(), [RoomEvent::Joined { epoch: 0, seq: 1 }]);
    assert_eq!(peer_obs.texts(), [(2, "owner-phone".to_string(), "hello pc".to_string())]);
    let sync = ok(peer.sync_state(), "peer sync");
    assert_eq!((sync.cursor, sync.joined, sync.acked), (2, true, 2), "persisted after the page: acked == cursor");

    let back = ok(peer.send(b"hello phone".to_vec()), "peer send");
    assert!(matches!(back, SendResult::Sent { seq: 3, .. }), "{back:?}");
    ok(owner.poll(), "owner poll");
    assert_eq!(owner_obs.texts(), [(3, "owner-pc".to_string(), "hello phone".to_string())]);
    assert!(owner_obs.events().iter().any(|e| matches!(e, RoomEvent::OwnEvent { seq: 2, .. })), "{:?}", owner_obs.events());

    // B-H2: every send persists (new sends counter) before the POST.
    let trace = h.trace();
    let persist = trace.iter().position(|l| l == "persist owner-phone cursor=0 sends=2").expect("persist before send");
    let post = trace.iter().position(|l| l.starts_with("POST application owner-phone-")).expect("post");
    assert!(persist < post, "{trace:?}");
    // The next GET acks what the first page persisted (the peer's own send does not move its cursor).
    ok(peer.poll(), "peer poll again");
    assert!(h.trace().iter().any(|l| l == "GET owner-pc after=2 ack=2"), "{:?}", h.trace());
    assert_eq!(ok(peer.sync_state(), "sync").cursor, 3, "its own echo moved the cursor");
}

#[test]
fn own_commit_merges_on_its_echo_and_the_peer_applies_it() {
    let h = Harness::new();
    let ((owner, owner_obs), (peer, peer_obs)) = founded_pair(&h);
    ok(peer.poll(), "peer joins");
    let (third, third_obs) = h.room("owner-tablet");
    let kp = ok(third.dispatch("key_package".into(), Vec::new()), "third key package");
    let framed = ok(owner.dispatch("invite_with_commit".into(), kp), "invite_with_commit");
    // `u32 LE commit_len ‖ commit ‖ welcome`
    let len = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    let (commit, welcome) = (framed[4..4 + len].to_vec(), framed[4 + len..].to_vec());

    let posted = ok(owner.post_commit(commit), "post commit");
    assert_eq!(posted.epoch, 1, "the relay moved its epoch");
    ok(owner.poll(), "owner sees its own commit");
    assert!(owner_obs.events().iter().any(|e| *e == RoomEvent::OwnCommitMerged { seq: posted.seq, epoch: 1 }), "{:?}", owner_obs.events());
    assert_eq!(ok(owner.sync_state(), "sync").epoch, 1);
    ok(owner.post_welcome(welcome, vec!["owner-tablet".into()]), "post welcome");

    ok(third.poll(), "third joins");
    assert!(third_obs.events().iter().any(|e| matches!(e, RoomEvent::Joined { .. })), "{:?}", third_obs.events());
    ok(peer.poll(), "peer applies the foreign commit");
    let applied = peer_obs.events().into_iter().find(|e| matches!(e, RoomEvent::CommitApplied { .. })).expect("commit applied");
    let RoomEvent::CommitApplied { committer, adds, members, outer_checked, .. } = applied else { unreachable!() };
    assert_eq!((committer.as_str(), adds, outer_checked), ("owner-phone", vec!["owner-tablet".to_string()], false));
    assert_eq!(members, ["owner-pc", "owner-phone", "owner-tablet"]);

    ok(owner.send(b"all three".to_vec()), "owner sends at epoch 1");
    ok(peer.poll(), "peer reads");
    ok(third.poll(), "third reads");
    assert_eq!(peer_obs.texts().last().map(|t| t.2.as_str()), Some("all three"));
    assert_eq!(third_obs.texts().last().map(|t| t.2.as_str()), Some("all three"));
}

#[test]
fn conflict_is_queued_and_replayed_after_the_next_poll() {
    let h = Harness::new();
    let ((owner, owner_obs), (peer, peer_obs)) = founded_pair(&h);
    ok(peer.poll(), "peer joins");
    h.relay.bump_epoch("room-a");

    let queued = ok(owner.send(b"late".to_vec()), "send into a moved room");
    let SendResult::Queued { client_id } = queued else { panic!("expected Queued, got {queued:?}") };
    assert_eq!(owner_obs.events().last(), Some(&RoomEvent::Conflict { client_id: client_id.clone(), attempt: 1 }));
    assert!(h.relay.rows("room-a").iter().all(|r| r.kind != "application"), "nothing stored on 409");

    ok(owner.poll(), "poll refreshes the epoch and replays");
    let replayed = owner_obs.events().into_iter().find(|e| matches!(e, RoomEvent::Replayed { .. })).expect("replayed");
    let RoomEvent::Replayed { client_id: replay_id, epoch, .. } = replayed else { unreachable!() };
    assert_ne!(replay_id, client_id, "a replay reserves a fresh dedup key");
    assert_eq!(epoch, 1);
    ok(peer.poll(), "peer reads the replayed message");
    assert_eq!(peer_obs.texts().last().map(|t| t.2.as_str()), Some("late"));
}

#[test]
fn import_resumes_from_the_last_persisted_state() {
    let h = Harness::new();
    let ((owner, _), (peer, peer_obs)) = founded_pair(&h);
    ok(owner.send(b"one".to_vec()), "one");
    ok(peer.poll(), "peer reads one");
    let (state, sync) = peer_obs.last_persisted();
    assert_eq!((sync.cursor, sync.joined, sync.sends), (2, true, 0));
    drop(peer);

    let again_obs = Observer::new("owner-pc-again", h.trace.clone());
    let again = ok(
        MlsRoom::import("owner-pc".into(), "room-a".into(), state, sync, BASE.into(), h.relay.clone(), again_obs.clone()),
        "import",
    );
    ok(owner.send(b"two".to_vec()), "two");
    ok(again.poll(), "resumed poll");
    assert_eq!(again_obs.texts(), [(3, "owner-phone".to_string(), "two".to_string())], "only what came after the cursor");
    let sent = ok(again.send(b"back".to_vec()), "resumed send");
    assert!(matches!(sent, SendResult::Sent { .. }), "the restored ratchet still encrypts: {sent:?}");

    let wrong_room = again_obs.last_persisted();
    let err = MlsRoom::import("owner-pc".into(), "room-b".into(), wrong_room.0, wrong_room.1, BASE.into(), h.relay.clone(), again_obs.clone())
        .err()
        .expect("state bound to its room");
    assert!(matches!(err, RoomError::Host { .. }), "{err}");
}

#[test]
fn transport_failure_is_a_transient_relay_error() {
    let h = Harness::new();
    let ((owner, _), _) = founded_pair(&h);
    h.relay.down.store(true, Ordering::SeqCst);
    let err = owner.poll().err().expect("relay down");
    assert!(matches!(err, RoomError::Relay { transient: true, .. }), "{err}");
    let err = owner.send(b"x".to_vec()).err().expect("relay down on send");
    assert!(matches!(err, RoomError::Relay { transient: true, .. }), "{err}");
    h.relay.down.store(false, Ordering::SeqCst);
    ok(owner.poll(), "back");
}

#[test]
fn pruned_history_halts_the_room_before_anything_moves() {
    let h = Harness::new();
    let ((owner, _), (peer, peer_obs)) = founded_pair(&h);
    ok(peer.poll(), "peer joins at seq 1");
    for text in ["a", "b", "c"] {
        ok(owner.send(text.as_bytes().to_vec()), text);
    }
    h.relay.prune_before("room-a", 4); // seqs 2..3 are gone for a reader at cursor 1
    ok(peer.poll(), "a gap is reported, not an error");
    let halts = peer_obs.halts.lock().unwrap().clone();
    assert_eq!(halts.len(), 1);
    assert_eq!(halts[0].0, "history_gap");
    assert!(halts[0].1.contains("missing 2..3"), "{}", halts[0].1);
    assert!(halts[0].2.halted);
    assert_eq!(ok(peer.sync_state(), "sync").cursor, 1, "nothing of the page moved");
    assert!(peer_obs.texts().is_empty());
    ok(peer.poll(), "halted room does nothing");
    assert_eq!(h.trace().iter().filter(|l| l.starts_with("GET owner-pc")).count(), 3, "no fetch while halted: {:?}", h.trace());
}
