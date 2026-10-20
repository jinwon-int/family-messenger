//! 호스트 게이트 공용 대역(`room_host.rs` · `lobby_host.rs`): Rust 로 구현한 in-memory 릴레이(`HttpTransport`)와 관찰자.
//! 릴레이는 와이어 JSON 만 흉내 내는 순서 매기기(MLS 검증 없음, cas 검사만) — v2 events 라우트(3a)에 3c 의 기기 수준 라우트
//! (로비 key package · 방 목록 · 방 닫기 · 푸시 등록)를 더했다. 규칙은 server/{server,lobby,rooms,push}.go 와 같다:
//! 로비는 가장 오래된 것부터 소비, `welcomes` 는 기기가 ack 로 지나가지 않은 Welcome 만, 닫힌 방은 410 `room_closed`.
#![allow(dead_code)]
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use family_mls_ios_ffi::{
    HttpHeader, HttpResponse, HttpTransport, LobbyObserver, MlsLobbySlot, MlsLobby, MlsRoom, RoomError, RoomEvent, RoomObserver,
    RoomSyncState,
};
use native_mls_host::b64;

pub const BASE: &str = "http://relay.test";
/// 릴레이 정책 기본값(server policy `LobbyKeyPackagesMaxPerDevice`)과 같다.
pub const LOBBY_MAX_DEFAULT: usize = 8;

#[derive(Clone)]
pub struct Row {
    pub seq: i64,
    pub device: String,
    pub client_id: String,
    pub kind: String,
    pub epoch: i64,
    pub bytes: Vec<u8>,
    pub targets: Vec<String>,
}

#[derive(Default)]
pub struct RoomRows {
    pub epoch: i64,
    pub next_seq: i64,
    pub rows: Vec<Row>,
    pub closed: bool,
    /// 바깥 로스터 흉내: 첫 게시자 + Welcome 대상(`GET /v2/rooms` 의 `member`).
    pub members: HashSet<String>,
    /// 기기별 마지막 ack(`welcomes` 가 "읽고 지나간" 판정에 쓴다).
    pub acks: HashMap<String, i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PushRow {
    pub device: String,
    pub token: Vec<u8>,
    pub topic: String,
}

pub struct Relay {
    pub rooms: Mutex<HashMap<String, RoomRows>>,
    /// 로비 풀: 기기 → (ref, bytes) 게시 순(가장 오래된 것부터 소비).
    pub lobby: Mutex<HashMap<String, VecDeque<(String, Vec<u8>)>>>,
    pub lobby_max: Mutex<usize>,
    pub push: Mutex<Vec<PushRow>>,
    pub trace: Arc<Mutex<Vec<String>>>,
    pub down: AtomicBool,
    /// 참이면 로비 게시를 409 `key_package_limit` 로 거부한다(상태는 여유가 있다고 답한 뒤 — 경합 흉내).
    pub refuse_lobby_post: AtomicBool,
}

impl Relay {
    pub fn new(trace: Arc<Mutex<Vec<String>>>) -> Arc<Relay> {
        Arc::new(Relay {
            rooms: Mutex::new(HashMap::new()),
            lobby: Mutex::new(HashMap::new()),
            lobby_max: Mutex::new(LOBBY_MAX_DEFAULT),
            push: Mutex::new(Vec::new()),
            trace,
            down: AtomicBool::new(false),
            refuse_lobby_post: AtomicBool::new(false),
        })
    }
    /// 다른 기기가 commit 을 올린 것처럼 epoch 만 올린다(cas_mismatch 유발).
    pub fn bump_epoch(&self, room: &str) {
        self.rooms.lock().unwrap().entry(room.into()).or_default().epoch += 1;
    }
    /// `before` 앞의 seq 를 정리한다(#268 history gap 유발).
    pub fn prune_before(&self, room: &str, before: i64) {
        self.rooms.lock().unwrap().entry(room.into()).or_default().rows.retain(|r| r.seq >= before);
    }
    pub fn rows(&self, room: &str) -> Vec<Row> {
        self.rooms.lock().unwrap().get(room).map(|r| r.rows.clone()).unwrap_or_default()
    }
    pub fn lobby_live(&self, device: &str) -> usize {
        self.lobby.lock().unwrap().get(device).map(VecDeque::len).unwrap_or(0)
    }
    pub fn set_lobby_max(&self, max: usize) {
        *self.lobby_max.lock().unwrap() = max;
    }
    /// steward 가 하는 일(`GET /v2/lobby/keypackages?device=&consumer=&room=`): 가장 오래된 로비 키 하나를 꺼낸다.
    pub fn consume_lobby(&self, device: &str, consumer: &str, room: &str) -> Option<Vec<u8>> {
        self.trace.lock().unwrap().push(format!("CONSUME lobby {device} by {consumer} for {room}"));
        self.lobby.lock().unwrap().get_mut(device).and_then(|q| q.pop_front()).map(|(_, bytes)| bytes)
    }
    pub fn push_rows(&self) -> Vec<PushRow> {
        self.push.lock().unwrap().clone()
    }

    fn respond(status: u16, body: serde_json::Value) -> Result<HttpResponse, RoomError> {
        Ok(HttpResponse { status, body: serde_json::to_vec(&body).unwrap() })
    }
    fn no_content() -> Result<HttpResponse, RoomError> {
        Ok(HttpResponse { status: 204, body: Vec::new() })
    }
    fn params(query: &str) -> HashMap<&str, &str> {
        query.split('&').filter_map(|kv| kv.split_once('=')).collect()
    }

    fn get_events(&self, room: &str, query: &str) -> Result<HttpResponse, RoomError> {
        let params = Self::params(query);
        let device = params["device"];
        let after: i64 = params["after"].parse().unwrap();
        self.trace.lock().unwrap().push(format!("GET {device} after={after} ack={}", params.get("ack").copied().unwrap_or("-")));
        let mut rooms = self.rooms.lock().unwrap();
        let Some(state) = rooms.get_mut(room) else {
            return Self::respond(404, serde_json::json!({ "error": "no_such_room" }));
        };
        if state.closed {
            return Self::respond(410, serde_json::json!({ "error": "room_closed" }));
        }
        if let Some(ack) = params.get("ack").and_then(|a| a.parse::<i64>().ok()) {
            state.acks.insert(device.to_string(), ack);
        }
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

    fn post_event(&self, room: &str, body: &[u8]) -> Result<HttpResponse, RoomError> {
        let post: serde_json::Value = serde_json::from_slice(body).expect("event post json");
        let field = |k: &str| post[k].as_str().unwrap_or_default().to_string();
        let (device, client_id, kind) = (field("device"), field("client_id"), field("kind"));
        let epoch = post["epoch"].as_i64().unwrap_or_default();
        self.trace.lock().unwrap().push(format!("POST {kind} {client_id}"));
        let mut rooms = self.rooms.lock().unwrap();
        let state = rooms.entry(room.into()).or_default();
        if state.closed {
            return Self::respond(410, serde_json::json!({ "error": "room_closed" }));
        }
        if let Some(existing) = state.rows.iter().find(|r| r.device == device && r.client_id == client_id) {
            return Self::respond(200, serde_json::json!({ "seq": existing.seq, "epoch": state.epoch, "revision": 0, "duplicate": true }));
        }
        if kind != "welcome" && epoch != state.epoch {
            return Self::respond(409, serde_json::json!({ "error": "cas_mismatch" }));
        }
        let targets: Vec<String> =
            post["targets"].as_array().map(|t| t.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
        state.members.insert(device.clone());
        state.members.extend(targets.iter().cloned());
        state.next_seq += 1;
        let seq = state.next_seq;
        state.rows.push(Row {
            seq, device, client_id, kind: kind.clone(), epoch: state.epoch,
            bytes: b64::decode(post["bytes"].as_str().unwrap_or_default()).expect("bytes b64"),
            targets,
        });
        if kind == "commit" {
            state.epoch += 1;
        }
        Self::respond(200, serde_json::json!({ "seq": seq, "epoch": state.epoch, "revision": 0, "duplicate": false }))
    }

    fn close_room(&self, room: &str, query: &str) -> Result<HttpResponse, RoomError> {
        let device = Self::params(query)["device"].to_string();
        self.trace.lock().unwrap().push(format!("CLOSE {room} by {device}"));
        let mut rooms = self.rooms.lock().unwrap();
        let Some(state) = rooms.get_mut(room) else {
            return Self::respond(404, serde_json::json!({ "error": "no_such_room" }));
        };
        if !state.members.contains(&device) {
            return Self::respond(403, serde_json::json!({ "error": "not_a_member" }));
        }
        state.closed = true;
        Self::respond(200, serde_json::json!({ "room": room, "closed": true }))
    }

    fn post_lobby(&self, body: &[u8]) -> Result<HttpResponse, RoomError> {
        let post: serde_json::Value = serde_json::from_slice(body).expect("key package post json");
        let device = post["device"].as_str().unwrap_or_default().to_string();
        let packages: Vec<(String, Vec<u8>)> = post["packages"]
            .as_array()
            .expect("packages")
            .iter()
            .map(|p| (p["ref"].as_str().unwrap().to_string(), b64::decode(p["bytes"].as_str().unwrap()).expect("kp b64")))
            .collect();
        self.trace.lock().unwrap().push(format!("POST lobby {device} n={}", packages.len()));
        let max = *self.lobby_max.lock().unwrap();
        let mut lobby = self.lobby.lock().unwrap();
        let pool = lobby.entry(device).or_default();
        if self.refuse_lobby_post.load(Ordering::SeqCst) || pool.len() + packages.len() > max {
            return Self::respond(409, serde_json::json!({ "error": "key_package_limit", "live": pool.len(), "max": max }));
        }
        let stored = packages.len();
        pool.extend(packages);
        Self::respond(201, serde_json::json!({ "stored": stored, "duplicates": 0, "live": pool.len() }))
    }

    fn consume_lobby_route(&self, query: &str) -> Result<HttpResponse, RoomError> {
        let p = Self::params(query);
        match self.consume_lobby(p["device"], p["consumer"], p["room"]) {
            Some(bytes) => Self::respond(200, serde_json::json!({ "ref": "", "bytes": b64::encode(&bytes), "expires_at": 0 })),
            None => Self::respond(404, serde_json::json!({ "error": "no_live_key_package" })),
        }
    }

    fn delete_lobby(&self, query: &str) -> Result<HttpResponse, RoomError> {
        let device = Self::params(query)["device"].to_string();
        self.trace.lock().unwrap().push(format!("DELETE lobby {device}"));
        let deleted = self.lobby.lock().unwrap().get_mut(&device).map(|q| std::mem::take(q).len()).unwrap_or(0);
        Self::respond(200, serde_json::json!({ "device": device, "deleted": deleted }))
    }

    fn lobby_status(&self, query: &str) -> Result<HttpResponse, RoomError> {
        let device = Self::params(query)["device"].to_string();
        self.trace.lock().unwrap().push(format!("STATUS lobby {device}"));
        let live = self.lobby_live(&device);
        let max = *self.lobby_max.lock().unwrap();
        Self::respond(200, serde_json::json!({ "device": device, "live": live, "max": max, "ttl_seconds": 2_592_000 }))
    }

    fn lobby_welcomes(&self, query: &str) -> Result<HttpResponse, RoomError> {
        let device = Self::params(query)["device"].to_string();
        self.trace.lock().unwrap().push(format!("WELCOMES {device}"));
        let rooms = self.rooms.lock().unwrap();
        let mut names: Vec<&String> = rooms.keys().collect();
        names.sort();
        let welcomes: Vec<serde_json::Value> = names
            .into_iter()
            .filter_map(|name| {
                let state = &rooms[name];
                if state.closed { return None; }
                let acked = state.acks.get(&device).copied().unwrap_or(0);
                state
                    .rows
                    .iter()
                    .find(|r| r.kind == "welcome" && r.targets.iter().any(|t| *t == device) && r.seq > acked)
                    .map(|r| serde_json::json!({ "room": name, "seq": r.seq, "epoch": r.epoch, "created_at": 0 }))
            })
            .collect();
        Self::respond(200, serde_json::json!({ "welcomes": welcomes }))
    }

    fn list_rooms(&self, query: &str) -> Result<HttpResponse, RoomError> {
        let device = Self::params(query)["device"].to_string();
        self.trace.lock().unwrap().push(format!("ROOMS {device}"));
        let rooms = self.rooms.lock().unwrap();
        let mut names: Vec<&String> = rooms.keys().collect();
        names.sort();
        let listing: Vec<serde_json::Value> = names
            .into_iter()
            .map(|name| {
                let state = &rooms[name];
                serde_json::json!({
                    "room": name, "epoch": state.epoch, "revision": 0, "member": state.members.contains(&device),
                    "keypackages_outstanding": 0, "closed": state.closed,
                })
            })
            .collect();
        Self::respond(200, serde_json::json!({ "rooms": listing }))
    }

    fn register_push(&self, body: &[u8]) -> Result<HttpResponse, RoomError> {
        let reg: serde_json::Value = serde_json::from_slice(body).expect("push registration json");
        let device = reg["device"].as_str().unwrap_or_default().to_string();
        let token = b64::decode(reg["apns_token"].as_str().unwrap_or_default()).expect("token b64");
        let topic = reg["topic"].as_str().unwrap_or_default().to_string();
        if token.is_empty() {
            return Self::respond(400, serde_json::json!({ "error": "bad_apns_token" }));
        }
        self.trace.lock().unwrap().push(format!("PUSH register {device} {topic}"));
        let mut push = self.push.lock().unwrap();
        push.retain(|p| !(p.device == device && p.token == token));
        push.push(PushRow { device, token, topic });
        Self::no_content()
    }

    fn unregister_push(&self, query: &str) -> Result<HttpResponse, RoomError> {
        let device = Self::params(query)["device"].to_string();
        self.trace.lock().unwrap().push(format!("PUSH unregister {device}"));
        self.push.lock().unwrap().retain(|p| p.device != device);
        Self::no_content()
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
        let body = body.unwrap_or_default();
        if let Some(rest) = path.strip_prefix("/v2/rooms/") {
            if let Some(room) = rest.strip_suffix("/events") {
                return match method.as_str() {
                    "GET" => self.get_events(room, query),
                    "POST" => self.post_event(room, &body),
                    other => panic!("unexpected method {other} on events"),
                };
            }
            if let Some(room) = rest.strip_suffix("/close") {
                assert_eq!(method, "POST");
                return self.close_room(room, query);
            }
        }
        match (method.as_str(), path) {
            ("GET", "/v2/rooms") => self.list_rooms(query),
            ("POST", "/v2/lobby/keypackages") => self.post_lobby(&body),
            ("GET", "/v2/lobby/keypackages") => self.consume_lobby_route(query),
            ("DELETE", "/v2/lobby/keypackages") => self.delete_lobby(query),
            ("GET", "/v2/lobby/status") => self.lobby_status(query),
            ("GET", "/v2/lobby/welcomes") => self.lobby_welcomes(query),
            ("POST", "/v2/push/devices") => self.register_push(&body),
            ("DELETE", "/v2/push/devices") => self.unregister_push(query),
            (m, p) => panic!("unexpected route {m} {p}"),
        }
    }
}

/// 방 관찰자: 영속·이벤트·메시지·정지를 전부 기록한다.
#[derive(Default)]
pub struct Observer {
    pub name: String,
    pub trace: Arc<Mutex<Vec<String>>>,
    pub persisted: Mutex<Vec<(Vec<u8>, RoomSyncState)>>,
    pub events: Mutex<Vec<RoomEvent>>,
    pub apps: Mutex<Vec<(i64, String, String, Vec<u8>)>>,
    pub halts: Mutex<Vec<(String, String, RoomSyncState)>>,
}

impl Observer {
    pub fn new(name: &str, trace: Arc<Mutex<Vec<String>>>) -> Arc<Observer> {
        Arc::new(Observer { name: name.into(), trace, ..Observer::default() })
    }
    pub fn events(&self) -> Vec<RoomEvent> { self.events.lock().unwrap().clone() }
    pub fn texts(&self) -> Vec<(i64, String, String)> {
        self.apps.lock().unwrap().iter().map(|(seq, from, _, pt)| (*seq, from.clone(), String::from_utf8_lossy(pt).into_owned())).collect()
    }
    pub fn last_persisted(&self) -> (Vec<u8>, RoomSyncState) { self.persisted.lock().unwrap().last().cloned().expect("persisted at least once") }
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

/// 로비 관찰자: 슬롯 영속을 기록한다(3c).
#[derive(Default)]
pub struct LobbyStore {
    pub name: String,
    pub trace: Arc<Mutex<Vec<String>>>,
    pub slots: Mutex<Vec<MlsLobbySlot>>,
}

impl LobbyStore {
    pub fn new(name: &str, trace: Arc<Mutex<Vec<String>>>) -> Arc<LobbyStore> {
        Arc::new(LobbyStore { name: name.into(), trace, ..LobbyStore::default() })
    }
    pub fn last(&self) -> MlsLobbySlot { self.slots.lock().unwrap().last().cloned().expect("lobby persisted at least once") }
    pub fn count(&self) -> usize { self.slots.lock().unwrap().len() }
}

impl LobbyObserver for LobbyStore {
    fn persist(&self, slot: MlsLobbySlot) -> Result<(), RoomError> {
        self.trace.lock().unwrap().push(format!("persist lobby {} published={}", self.name, slot.published.len()));
        self.slots.lock().unwrap().push(slot);
        Ok(())
    }
}

pub struct Harness {
    pub relay: Arc<Relay>,
    pub trace: Arc<Mutex<Vec<String>>>,
}

impl Harness {
    pub fn new() -> Harness {
        let trace = Arc::new(Mutex::new(Vec::new()));
        Harness { relay: Relay::new(trace.clone()), trace }
    }
    /// `room-a` 의 새 신원.
    pub fn room(&self, identity: &str) -> (Arc<MlsRoom>, Arc<Observer>) {
        self.room_in(identity, "room-a")
    }
    pub fn room_in(&self, identity: &str, room: &str) -> (Arc<MlsRoom>, Arc<Observer>) {
        let observer = Observer::new(identity, self.trace.clone());
        let room = MlsRoom::new(identity.into(), room.into(), BASE.into(), self.relay.clone(), observer.clone())
            .unwrap_or_else(|e| panic!("room {identity}: {e}"));
        (room, observer)
    }
    pub fn lobby(&self, identity: &str) -> (Arc<MlsLobby>, Arc<LobbyStore>) {
        let store = LobbyStore::new(identity, self.trace.clone());
        let lobby = MlsLobby::new(identity.into(), BASE.into(), self.relay.clone(), store.clone())
            .unwrap_or_else(|e| panic!("lobby {identity}: {e}"));
        (lobby, store)
    }
    pub fn trace(&self) -> Vec<String> { self.trace.lock().unwrap().clone() }
}

pub fn ok<T>(result: Result<T, impl std::fmt::Display>, what: &str) -> T {
    match result {
        Ok(value) => value,
        Err(err) => panic!("{what}: {err}"),
    }
}

/// owner 가 방을 만들고 peer 를 `invite`(로컬 merge) → Welcome 을 올린다 → peer 가 poll 로 join 한다.
pub fn founded_pair(h: &Harness) -> ((Arc<MlsRoom>, Arc<Observer>), (Arc<MlsRoom>, Arc<Observer>)) {
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
