//! 호스트 게이트 공용 대역(`room_host.rs` · `lobby_host.rs`): Rust 로 구현한 in-memory 릴레이(`HttpTransport`)와 관찰자.
//! 릴레이는 와이어 JSON 만 흉내 내는 순서 매기기(MLS 검증 없음, cas 검사만) — v2 events 라우트(3a)에 3c 의 기기 수준 라우트
//! (로비 key package · 방 목록 · 방 닫기 · 푸시 등록)와 #574 의 기기 셀프서비스(`/v2/me` · 후보 우편함 · 승인 · 역할; 체인 대역은
//! revision CAS·subject 바인딩·registrar 규칙만, Ed25519 검증은 길이만)를 더했다. 규칙은 server/{server,lobby,rooms,push,devices,me}.go
//! 와 같다: 로비는 가장 오래된 것부터 소비, `welcomes` 는 기기가 ack 로 지나가지 않은 Welcome 만(`from` 포함), 닫힌 방은 410 `room_closed`.
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
    /// 읽음 위치(#571 B, read.go): **actor** 별 하나(`max`). actor = 기기 ID 의 첫 `-` 앞(실제 릴레이는 mls_members.actor).
    pub reads: HashMap<String, i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PushRow {
    pub device: String,
    pub token: Vec<u8>,
    pub topic: String,
}

/// 호출자 subject 대역(#574): 토큰이 없는 테스트라 모든 요청이 이 사람이다(me.go `c.subject`).
pub const SUBJECT: &str = "person-owner";
/// 후보 TTL(devices.go `candidateTTL`), 초.
pub const CANDIDATE_TTL_SECONDS: i64 = 600;

/// 정책 체인의 기기 하나(DEVICES-V4 레코드의 공개 필드).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChainDevice {
    pub device_id: String,
    pub actor: String,
    pub subject: String,
    pub fingerprint: String,
    pub status: String,
    pub roles: Vec<String>,
}

/// 우편함의 후보 행(devices.go `candidateView`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CandidateRow {
    pub device_id: String,
    pub actor: String,
    pub subject: String,
    pub signing_key: String,
    pub fingerprint: String,
    pub created_at: i64,
    pub expires_at: i64,
}

/// 기기 정책 체인 대역(server/devices.go · me.go · devicepolicy Verify* 의 규칙만, 서명 검증은 길이만): revision CAS ·
/// 같은 subject 바인딩 · registrar 규칙(registrar 가 있는 actor 는 registrar 서명만, 마지막 registrar 해제 불가).
#[derive(Default)]
pub struct Chain {
    pub revision: u64,
    pub devices: Vec<ChainDevice>,
    pub candidates: Vec<CandidateRow>,
    /// 시계 대역(초) — 후보 TTL.
    pub now: i64,
}

pub struct Relay {
    pub rooms: Mutex<HashMap<String, RoomRows>>,
    /// 로비 풀: 기기 → (ref, bytes) 게시 순(가장 오래된 것부터 소비).
    pub lobby: Mutex<HashMap<String, VecDeque<(String, Vec<u8>)>>>,
    pub lobby_max: Mutex<usize>,
    pub push: Mutex<Vec<PushRow>>,
    pub chain: Mutex<Chain>,
    pub trace: Arc<Mutex<Vec<String>>>,
    pub down: AtomicBool,
    /// 참이면 로비 게시를 409 `key_package_limit` 로 거부한다(상태는 여유가 있다고 답한 뒤 — 경합 흉내).
    pub refuse_lobby_post: AtomicBool,
    /// 참이면 #571 B 이전 릴레이 흉내: `GET /events` 에 `read_seq` 가 없고 `POST /read` 는 봉투 없는 404(Go mux 기본 응답).
    pub no_read_route: AtomicBool,
    /// 참이면 #574 이전(또는 호출자 인증·기기 저장소 없는) 릴레이 흉내: `/v2/me` 는 `{subject}` 만, 셀프서비스 라우트는 봉투 없는 404,
    /// `welcomes` 에 `from` 없음.
    pub no_self_service: AtomicBool,
    /// 한 번만 터지는 전송 고장(#574 후속 — 대기 Welcome 영속): 다음 `POST welcome` / 다음 `GET /events` / 다음 `POST commit` 이
    /// 연결 끊김(transient)으로 실패하고 플래그가 꺼진다. commit 은 릴레이에 **닿지 않는다**(행 없음).
    pub fail_next_welcome: AtomicBool,
    pub fail_next_get: AtomicBool,
    pub drop_next_commit: AtomicBool,
}

impl Relay {
    pub fn new(trace: Arc<Mutex<Vec<String>>>) -> Arc<Relay> {
        Arc::new(Relay {
            rooms: Mutex::new(HashMap::new()),
            lobby: Mutex::new(HashMap::new()),
            lobby_max: Mutex::new(LOBBY_MAX_DEFAULT),
            push: Mutex::new(Vec::new()),
            chain: Mutex::new(Chain { revision: 1, ..Chain::default() }),
            trace,
            down: AtomicBool::new(false),
            refuse_lobby_post: AtomicBool::new(false),
            no_read_route: AtomicBool::new(false),
            no_self_service: AtomicBool::new(false),
            fail_next_welcome: AtomicBool::new(false),
            fail_next_get: AtomicBool::new(false),
            drop_next_commit: AtomicBool::new(false),
        })
    }
    fn cut() -> Result<HttpResponse, RoomError> {
        Err(RoomError::Host { reason: "connection reset (test)".into() })
    }
    /// 운영자 CLI 대역(`-enroll-first`/`-add-device`): 호출자 subject 의 활성 기기를 체인에 올린다. revision 이 하나 오른다.
    pub fn enroll(&self, device_id: &str, fingerprint: &str, roles: &[&str]) {
        let mut chain = self.chain.lock().unwrap();
        chain.devices.push(ChainDevice {
            device_id: device_id.into(), actor: Self::actor_of(device_id), subject: SUBJECT.into(), fingerprint: fingerprint.into(),
            status: "active".into(), roles: roles.iter().map(|r| (*r).to_string()).collect(),
        });
        chain.revision += 1;
    }
    pub fn chain_device(&self, device_id: &str) -> Option<ChainDevice> {
        self.chain.lock().unwrap().devices.iter().find(|d| d.device_id == device_id).cloned()
    }
    pub fn policy_revision(&self) -> u64 {
        self.chain.lock().unwrap().revision
    }
    pub fn candidates(&self) -> Vec<CandidateRow> {
        self.chain.lock().unwrap().candidates.clone()
    }
    /// 시계를 앞으로(후보 TTL 검사).
    pub fn advance_clock(&self, seconds: i64) {
        self.chain.lock().unwrap().now += seconds;
    }
    fn sha256_hex(bytes: &[u8]) -> String {
        use sha2::{Digest, Sha256};
        Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
    }
    fn unhex(text: &str) -> Option<Vec<u8>> {
        if text.len() % 2 != 0 || !text.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()) { return None; }
        (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).ok()).collect()
    }
    fn bare_404() -> Result<HttpResponse, RoomError> {
        Ok(HttpResponse { status: 404, body: b"404 page not found\n".to_vec() })
    }
    fn strict(body: &[u8], keys: &[&str]) -> Result<serde_json::Map<String, serde_json::Value>, HttpResponse> {
        let post: serde_json::Value = serde_json::from_slice(body).map_err(|_| HttpResponse { status: 400, body: br#"{"error":"bad_request"}"#.to_vec() })?;
        let object = post.as_object().cloned().unwrap_or_default();
        let mut got: Vec<&str> = object.keys().map(String::as_str).collect();
        got.sort_unstable();
        let mut want = keys.to_vec();
        want.sort_unstable();
        assert_eq!(got, want, "strict body: {post}");
        Ok(object)
    }

    fn get_me(&self) -> Result<HttpResponse, RoomError> {
        self.trace.lock().unwrap().push("ME".into());
        if self.no_self_service.load(Ordering::SeqCst) {
            return Self::respond(200, serde_json::json!({ "subject": SUBJECT }));
        }
        let chain = self.chain.lock().unwrap();
        let devices: Vec<serde_json::Value> = chain
            .devices
            .iter()
            .filter(|d| d.subject == SUBJECT)
            .map(|d| serde_json::json!({
                "device_id": d.device_id, "actor": d.actor, "fingerprint": d.fingerprint, "status": d.status,
                "acceptance": "trusted-device-fingerprint", "roles": d.roles,
            }))
            .collect();
        Self::respond(200, serde_json::json!({ "subject": SUBJECT, "policy_revision": chain.revision, "devices": devices }))
    }

    /// devices.go `handlePostCandidate`: 엄격 본문(subject 없음) · 지문 = sha256(공개키) · 이미 체인에 있는 ID 는 409 · 호출자에게
    /// 활성 기기가 없으면 403 `first_device_out_of_band` · 같은 ID 재게시는 갱신.
    fn post_candidate(&self, body: &[u8]) -> Result<HttpResponse, RoomError> {
        if self.no_self_service.load(Ordering::SeqCst) { return Self::bare_404(); }
        let post = match Self::strict(body, &["device_id", "actor", "signing_key", "fingerprint"]) { Ok(p) => p, Err(r) => return Ok(r) };
        let field = |k: &str| post[k].as_str().unwrap_or_default().to_string();
        let (device_id, actor, signing_key, fingerprint) = (field("device_id"), field("actor"), field("signing_key"), field("fingerprint"));
        self.trace.lock().unwrap().push(format!("CANDIDATE {device_id}"));
        let Some(key) = Self::unhex(&signing_key).filter(|k| k.len() == 32) else {
            return Self::respond(400, serde_json::json!({ "error": "bad_candidate", "detail": "signing_key" }));
        };
        let computed = Self::sha256_hex(&key);
        if !fingerprint.is_empty() && fingerprint != computed {
            return Self::respond(400, serde_json::json!({ "error": "bad_candidate", "detail": "fingerprint does not match signing_key" }));
        }
        let mut chain = self.chain.lock().unwrap();
        if chain.devices.iter().any(|d| d.device_id == device_id) {
            return Self::respond(409, serde_json::json!({ "error": "device_exists", "detail": "ids are never reused; start again with a new device id" }));
        }
        if !chain.devices.iter().any(|d| d.subject == SUBJECT && d.status == "active") {
            return Self::respond(403, serde_json::json!({ "error": "first_device_out_of_band" }));
        }
        let (now, revision) = (chain.now, chain.revision);
        chain.candidates.retain(|c| c.expires_at > now && c.device_id != device_id);
        let expires_at = now + CANDIDATE_TTL_SECONDS;
        chain.candidates.push(CandidateRow { device_id: device_id.clone(), actor, subject: SUBJECT.into(), signing_key, fingerprint: computed.clone(), created_at: now, expires_at });
        Self::respond(201, serde_json::json!({ "device_id": device_id, "fingerprint": computed, "policy_revision": revision, "expires_at": expires_at }))
    }

    /// `GET /v2/devices/candidates?device=`: bindDevice(활성·호출자 소유) 뒤 우편함.
    fn list_candidates(&self, query: &str) -> Result<HttpResponse, RoomError> {
        if self.no_self_service.load(Ordering::SeqCst) { return Self::bare_404(); }
        let device = Self::params(query)["device"].to_string();
        self.trace.lock().unwrap().push(format!("CANDIDATES {device}"));
        let mut chain = self.chain.lock().unwrap();
        if !chain.devices.iter().any(|d| d.device_id == device && d.subject == SUBJECT && d.status == "active") {
            return Self::respond(403, serde_json::json!({ "error": "device_not_allowed" }));
        }
        let now = chain.now;
        chain.candidates.retain(|c| c.expires_at > now);
        let rows: Vec<serde_json::Value> = chain
            .candidates
            .iter()
            .filter(|c| c.subject == SUBJECT)
            .map(|c| serde_json::json!({
                "device_id": c.device_id, "actor": c.actor, "subject": c.subject, "signing_key": c.signing_key, "fingerprint": c.fingerprint,
                "created_at": c.created_at, "expires_at": c.expires_at,
            }))
            .collect();
        Self::respond(200, serde_json::json!({ "policy_revision": chain.revision, "candidates": rows }))
    }

    /// devicepolicy.VerifyApproval/VerifyRoles 의 서명자 규칙: 활성이고, registrar 이거나 그 actor 에 활성 registrar 가 없다.
    fn approver_allowed(chain: &Chain, approver: &str, actor: &str) -> Result<(), String> {
        let Some(a) = chain.devices.iter().find(|d| d.device_id == approver) else { return Err(format!("approver {approver} is not on the chain")) };
        if a.status != "active" { return Err(format!("approver {approver} is not active")); }
        if a.actor != actor { return Err(format!("approver {approver} is another actor")); }
        let has_registrar = chain.devices.iter().any(|d| d.actor == actor && d.status == "active" && d.roles.iter().any(|r| r == "registrar"));
        if has_registrar && !a.roles.iter().any(|r| r == "registrar") { return Err(format!("approver {approver} is not a registrar")); }
        Ok(())
    }

    /// `POST /v2/devices/approvals` = AddDeviceEvidence(엄격): subject 바인딩 → revision CAS → 서명자 규칙 → 체인 commit → 후보 삭제.
    fn post_approval(&self, body: &[u8]) -> Result<HttpResponse, RoomError> {
        if self.no_self_service.load(Ordering::SeqCst) { return Self::bare_404(); }
        let ev = match Self::strict(body, &["device_id", "actor", "subject", "signing_key", "base_revision", "signature", "fingerprint", "approved_by"]) {
            Ok(p) => p, Err(r) => return Ok(r),
        };
        let field = |k: &str| ev[k].as_str().unwrap_or_default().to_string();
        let (device_id, actor, approver) = (field("device_id"), field("actor"), field("approved_by"));
        self.trace.lock().unwrap().push(format!("APPROVE {device_id} by {approver}"));
        if field("subject") != SUBJECT {
            return Self::respond(403, serde_json::json!({ "error": "subject_mismatch" }));
        }
        let mut chain = self.chain.lock().unwrap();
        let base = ev["base_revision"].as_u64().unwrap_or(0);
        if base != chain.revision {
            return Self::respond(409, serde_json::json!({ "error": "stale_revision", "detail": format!("base_revision {base} != {}", chain.revision), "revision": chain.revision }));
        }
        if field("signature").len() != 128 || Self::unhex(&field("signature")).is_none() {
            return Self::respond(403, serde_json::json!({ "error": "approval_rejected", "detail": "signature" }));
        }
        let key = Self::unhex(&field("signing_key")).filter(|k| k.len() == 32);
        if key.as_deref().map(Self::sha256_hex) != Some(field("fingerprint")) {
            return Self::respond(400, serde_json::json!({ "error": "bad_candidate", "detail": "fingerprint" }));
        }
        if chain.devices.iter().any(|d| d.device_id == device_id) {
            return Self::respond(400, serde_json::json!({ "error": "bad_candidate", "detail": "duplicate id" }));
        }
        if let Err(detail) = Self::approver_allowed(&chain, &approver, &actor) {
            return Self::respond(403, serde_json::json!({ "error": "approval_rejected", "detail": detail }));
        }
        chain.devices.push(ChainDevice {
            device_id: device_id.clone(), actor, subject: SUBJECT.into(), fingerprint: field("fingerprint"), status: "active".into(), roles: Vec::new(),
        });
        chain.revision += 1;
        chain.candidates.retain(|c| c.device_id != device_id);
        Self::respond(201, serde_json::json!({ "device_id": device_id, "approved_by": approver, "revision": chain.revision }))
    }

    /// `POST /v2/devices/roles` = RolesEvidence(엄격): 대상·승인자 호출자 소유 → CAS → 서명자 규칙 → 마지막 registrar 보호 → commit.
    fn post_roles(&self, body: &[u8]) -> Result<HttpResponse, RoomError> {
        if self.no_self_service.load(Ordering::SeqCst) { return Self::bare_404(); }
        let ev = match Self::strict(body, &["device_id", "actor", "roles", "base_revision", "signature", "approved_by"]) { Ok(p) => p, Err(r) => return Ok(r) };
        let field = |k: &str| ev[k].as_str().unwrap_or_default().to_string();
        let (device_id, actor, approver) = (field("device_id"), field("actor"), field("approved_by"));
        let roles: Vec<String> = ev["roles"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
        self.trace.lock().unwrap().push(format!("ROLES {device_id} {roles:?} by {approver}"));
        let mut chain = self.chain.lock().unwrap();
        let Some(target) = chain.devices.iter().position(|d| d.device_id == device_id && d.subject == SUBJECT) else {
            return Self::respond(403, serde_json::json!({ "error": "device_subject_mismatch" }));
        };
        let base = ev["base_revision"].as_u64().unwrap_or(0);
        if base != chain.revision {
            return Self::respond(409, serde_json::json!({ "error": "stale_revision", "detail": format!("base_revision {base} != {}", chain.revision), "revision": chain.revision }));
        }
        if chain.devices[target].status != "active" || chain.devices[target].actor != actor {
            return Self::respond(403, serde_json::json!({ "error": "approval_rejected", "detail": "target is not an active device of that actor" }));
        }
        if let Err(detail) = Self::approver_allowed(&chain, &approver, &actor) {
            return Self::respond(403, serde_json::json!({ "error": "approval_rejected", "detail": detail }));
        }
        let was_registrar = chain.devices[target].roles.iter().any(|r| r == "registrar");
        let registrars = chain.devices.iter().filter(|d| d.actor == actor && d.status == "active" && d.roles.iter().any(|r| r == "registrar")).count();
        if was_registrar && !roles.iter().any(|r| r == "registrar") && registrars <= 1 {
            return Self::respond(403, serde_json::json!({ "error": "approval_rejected", "detail": "last registrar of the actor cannot release the role" }));
        }
        chain.devices[target].roles = roles.clone();
        chain.revision += 1;
        Self::respond(201, serde_json::json!({ "device_id": device_id, "roles": roles, "approved_by": approver, "revision": chain.revision }))
    }
    /// 릴레이가 보관한 actor 의 읽음 위치(없으면 0).
    pub fn read_seq(&self, room: &str, actor: &str) -> i64 {
        self.rooms.lock().unwrap().get(room).and_then(|r| r.reads.get(actor).copied()).unwrap_or(0)
    }
    /// read.go 와 같은 키: 실제 릴레이는 mls_members.actor, 대역은 기기 ID 의 첫 `-` 앞.
    fn actor_of(device: &str) -> String {
        device.split('-').next().unwrap_or(device).to_string()
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
        if self.fail_next_get.swap(false, Ordering::SeqCst) {
            self.trace.lock().unwrap().push(format!("CUT GET {device}"));
            return Self::cut();
        }
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
        let mut page = serde_json::json!({ "epoch": state.epoch, "revision": 0, "events": events, "first_seq": first_seq });
        if !self.no_read_route.load(Ordering::SeqCst) {
            page["read_seq"] = serde_json::json!(state.reads.get(&Self::actor_of(device)).copied().unwrap_or(0));
        }
        Self::respond(200, page)
    }

    /// `POST /v2/rooms/{room}/read {device, seq}`(#571 B, read.go `handlePostRead`/`markRead`): 404 · 410 · 403 `not_a_member`
    /// · 400 `bad_seq`(0..last_seq 밖) 순서로 거르고, (방, actor) 값을 `max` 로 올린 뒤 그 값을 답한다.
    fn post_read(&self, room: &str, body: &[u8]) -> Result<HttpResponse, RoomError> {
        if self.no_read_route.load(Ordering::SeqCst) {
            return Ok(HttpResponse { status: 404, body: b"404 page not found\n".to_vec() });
        }
        let post: serde_json::Value = serde_json::from_slice(body).expect("read post json");
        let object = post.as_object().expect("read post object");
        assert_eq!(object.len(), 2, "strict body: exactly device and seq ({post})");
        let device = post["device"].as_str().expect("device").to_string();
        let seq = post["seq"].as_i64().expect("seq");
        self.trace.lock().unwrap().push(format!("READ {device} seq={seq}"));
        let mut rooms = self.rooms.lock().unwrap();
        let Some(state) = rooms.get_mut(room) else {
            return Self::respond(404, serde_json::json!({ "error": "no_such_room" }));
        };
        if state.closed {
            return Self::respond(410, serde_json::json!({ "error": "room_closed" }));
        }
        if !state.members.contains(&device) {
            return Self::respond(403, serde_json::json!({ "error": "not_a_member" }));
        }
        if seq < 0 || seq > state.next_seq {
            return Self::respond(400, serde_json::json!({ "error": "bad_seq" }));
        }
        let read = state.reads.entry(Self::actor_of(&device)).or_insert(0);
        *read = (*read).max(seq);
        Self::respond(200, serde_json::json!({ "read_seq": *read }))
    }

    fn post_event(&self, room: &str, body: &[u8]) -> Result<HttpResponse, RoomError> {
        let post: serde_json::Value = serde_json::from_slice(body).expect("event post json");
        let field = |k: &str| post[k].as_str().unwrap_or_default().to_string();
        let (device, client_id, kind) = (field("device"), field("client_id"), field("kind"));
        let epoch = post["epoch"].as_i64().unwrap_or_default();
        self.trace.lock().unwrap().push(format!("POST {kind} {client_id}"));
        if (kind == "welcome" && self.fail_next_welcome.swap(false, Ordering::SeqCst))
            || (kind == "commit" && self.drop_next_commit.swap(false, Ordering::SeqCst))
        {
            self.trace.lock().unwrap().push(format!("CUT POST {kind} {client_id}"));
            return Self::cut();
        }
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
            Some(bytes) => Self::respond(200, serde_json::json!({ "ref": Self::sha256_hex(&bytes), "bytes": b64::encode(&bytes), "expires_at": 0 })),
            None => Self::respond(404, serde_json::json!({ "error": "no_live_key_package" })),
        }
    }

    /// 방 풀 소비(`GET /v2/rooms/{room}/keypackages?device=&consumer=`): 대역에는 방 풀이 없다 — 늘 404 `no_live_key_package`
    /// (→ `MlsRoom::invite` 가 로비로 넘어간다, #380).
    fn consume_room_route(&self, room: &str, query: &str) -> Result<HttpResponse, RoomError> {
        let p = Self::params(query);
        self.trace.lock().unwrap().push(format!("CONSUME room {} by {} for {room}", p["device"], p["consumer"]));
        Self::respond(404, serde_json::json!({ "error": "no_live_key_package" }))
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
                    .map(|r| {
                        let mut w = serde_json::json!({ "room": name, "seq": r.seq, "epoch": r.epoch, "created_at": 0 });
                        // #574: 보낸 기기 — 옛 릴레이 흉내에서는 없다.
                        if !self.no_self_service.load(Ordering::SeqCst) { w["from"] = serde_json::json!(r.device); }
                        w
                    })
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
            if let Some(room) = rest.strip_suffix("/read") {
                assert_eq!(method, "POST");
                return self.post_read(room, &body);
            }
            if let Some(room) = rest.strip_suffix("/keypackages") {
                assert_eq!(method, "GET");
                return self.consume_room_route(room, query);
            }
        }
        match (method.as_str(), path) {
            ("GET", "/v2/rooms") => self.list_rooms(query),
            ("GET", "/v2/me") => self.get_me(),
            ("POST", "/v2/devices/candidates") => self.post_candidate(&body),
            ("GET", "/v2/devices/candidates") => self.list_candidates(query),
            ("POST", "/v2/devices/approvals") => self.post_approval(&body),
            ("POST", "/v2/devices/roles") => self.post_roles(&body),
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
