//! #366 3a — 모바일 호스트(Android 먼저)용 방 객체 `MlsRoom`: 동기화(`room::poll`)·송신(`room::send_application`)·
//! 릴레이 와이어(`api::Client`)는 봇과 같은 host-core 코드가 돌고, 호스트는 두 콜백만 구현한다.
//!
//! - [`HttpTransport`]: HTTP 바이트 전송(Kotlin OkHttp — TLS 는 거기). 경로·쿼리·JSON·오류 봉투는 Rust 가 만든다.
//!   연결 실패만 `Err` 로 돌려준다(→ `RelayError::Http(Io)`, `is_transient` 참); 오류 상태 코드는 보통의 응답이다.
//! - [`RoomObserver`]: 영속(`persist` — bytes 가 나가기 전, review 2 B-H2)·로그(`event`)·복호화된 메시지(`application`)·
//!   정지(`halted` — 정지 마커 영속은 호스트 몫, #263/#268).
//!
//! 프레이밍은 봇 `session.rs` 와 바이트 단위로 같다(encrypt `u32le len‖room‖u32le len‖client_id‖plaintext`,
//! decrypt 입력 `u32le len‖room‖ciphertext`, AAD client_id = 기기 identity — review H1). 릴레이 dedup client_id 는
//! iOS 와 같은 모양 `<identity>-<8 hex>`(봇의 `-echo-` 형식은 쓰지 않는다 — 봇이 echo 로 오인).
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard};

use family_mls_browser_experiment::Device;
use native_mls_host::api::{self, Access, Client, EventPost, RelayError, StoredRow};
use native_mls_host::http::{HttpError, Response};
use native_mls_host::room::{self, Halt, RoomAccess, RoomSync, SendOutcome, SyncEvent};
use zeroize::Zeroizing;

use crate::{dispatch_guarded, rejected, MlsError};

/// `MlsRoom` 의 오류. 기존 `MlsError`(iOS 가 두 case 를 exhaustive 로 잡는다)는 손대지 않는다.
#[derive(Debug, uniffi::Error)]
pub enum RoomError {
    /// 릴레이 왕복 실패. `transient` 가 참이면(연결 실패·502~504) 호스트가 백오프 뒤 다시 부른다(#392).
    Relay { reason: String, transient: bool },
    /// 파사드가 거부했다 / 롤백 실패(재등록 필요) / 암호화 실패.
    Mls { reason: String },
    /// 호스트 콜백 오류·전제 위반(잘못된 identity, 다른 방의 상태 import, 잠금 오염).
    Host { reason: String },
}

impl std::fmt::Display for RoomError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RoomError::Relay { reason, transient } => write!(f, "relay: {reason} (transient: {transient})"),
            RoomError::Mls { reason } => write!(f, "mls: {reason}"),
            RoomError::Host { reason } => write!(f, "host: {reason}"),
        }
    }
}

/// 외부 구현 trait 이 `Result` 를 돌려주려면 필요(uniffi 콜백 계약).
impl From<uniffi::UnexpectedUniFFICallbackError> for RoomError {
    fn from(e: uniffi::UnexpectedUniFFICallbackError) -> Self {
        RoomError::Host { reason: e.reason }
    }
}

pub(crate) fn relay_err(e: RelayError) -> RoomError {
    match e {
        // host-core `room` 의 로컬 오류는 전부 MLS 쪽(스냅샷·롤백·암호화).
        RelayError::Local(what) => RoomError::Mls { reason: what.to_string() },
        RelayError::Detail(what) => RoomError::Host { reason: what },
        other => RoomError::Relay { transient: room::is_transient(&other), reason: other.to_string() },
    }
}

fn host_err(e: RoomError) -> RelayError {
    RelayError::Detail(e.to_string())
}

pub(crate) fn mls_err(e: MlsError) -> RoomError {
    RoomError::Mls { reason: e.to_string() }
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct HttpHeader {
    pub name: String,
    pub value: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

/// 방 동기화 위치(호스트가 `export_state` 바이트와 함께 영속한다; `import` 로 되돌린다).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct RoomSyncState {
    pub room: String,
    /// 본 가장 큰 seq(처리했든 건너뛰었든).
    pub cursor: i64,
    /// 마지막 페이지의 릴레이 방 epoch.
    pub epoch: i64,
    pub joined: bool,
    /// Welcome 을 받아들이는가(감시 전용 방은 거짓).
    pub joinable: bool,
    /// 릴레이가 여기까지 정리해도 되는 커서(영속된 처리 위치, B-H4).
    pub acked: i64,
    pub ack_sent: i64,
    pub ack_disabled: bool,
    /// 거부된 commit 또는 잘린 이력(#263/#268): 더는 읽지도 ack 하지도 않는다.
    pub halted: bool,
    /// 지금까지 예약한 송신 dedup 키 수 — 재시작 뒤 같은 키를 다시 내지 않게 영속한다.
    pub sends: u64,
}

/// `RoomObserver::event` 어휘 — 봇의 JSON 로그 이벤트와 같은 이름·필드.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum RoomEvent {
    AckRefused { ack: i64, status: u16, code: String },
    Joined { epoch: i64, seq: i64 },
    WelcomeIgnored { seq: i64, joined: bool },
    /// 파사드가 거부한 poison Welcome/commit — 롤백됐고 커서는 지나간다.
    Rejected { seq: i64, kind: String, bytes: u64 },
    CommitApplied { seq: i64, committer: String, epoch: i64, adds: Vec<String>, removes: Vec<String>, members: Vec<String>, outer_checked: bool },
    Undecryptable { seq: i64, bytes: u64 },
    /// 이 기기가 올린 이벤트의 echo(MLS 는 자기 메시지를 처리하지 않는다).
    OwnEvent { seq: i64, kind: String },
    /// 이 기기가 올린(pending) commit 의 echo 를 merge 했다 — 초대라면 이제 Welcome 을 보낸다(`post_welcome`).
    OwnCommitMerged { seq: i64, epoch: i64 },
    OwnCommitMergeRejected { seq: i64 },
    /// 409 cas_mismatch: 다음 `poll` 뒤 새 epoch 로 다시 보낸다(최대 8회).
    Conflict { client_id: String, attempt: u32 },
    /// 409 client_id_reuse: 이전 실행이 이미 보냈다 — 릴레이에 있다, 넘어간다.
    AlreadyDelivered { client_id: String },
    /// 재시도 큐의 메시지가 새 epoch 로 나갔다.
    Replayed { client_id: String, seq: i64, epoch: i64 },
    /// 재시도 한도 초과 또는 전송 오류로 버렸다(호스트가 outbox 에서 다시 시도할 수 있게 바이트 수만).
    Dropped { bytes: u64, error: String },
}

#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum SendResult {
    Sent { client_id: String, seq: i64, epoch: i64, duplicate: bool },
    /// 409 cas_mismatch — 방이 움직였다. 다음 `poll` 이 새 epoch 로 다시 보낸다.
    Queued { client_id: String },
    AlreadyDelivered { client_id: String },
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PostedEvent {
    pub seq: i64,
    pub epoch: i64,
    pub duplicate: bool,
}

/// HTTP 바이트 전송(호스트 구현). `url` = base + 경로·쿼리, `headers` 에는 CF Access 헤더가 들어 있을 수 있다.
#[uniffi::export(foreign)]
pub trait HttpTransport: Send + Sync {
    fn send(&self, method: String, url: String, headers: Vec<HttpHeader>, body: Option<Vec<u8>>) -> Result<HttpResponse, RoomError>;
}

/// 방 관찰자(호스트 구현).
#[uniffi::export(foreign)]
pub trait RoomObserver: Send + Sync {
    /// 그룹 상태와 동기화 위치를 원자적으로 저장한다(tmp→fsync→rename). 돌아오기 전에는 바이트가 나가지 않는다.
    fn persist(&self, state: Vec<u8>, sync: RoomSyncState) -> Result<(), RoomError>;
    fn event(&self, event: RoomEvent);
    /// 다른 기기의 복호화된 application 메시지(페이지 순서). `client_id` 가 `file-v1-…` 이면 첨부(relay-app 규칙).
    fn application(&self, seq: i64, sender: String, client_id: String, plaintext: Vec<u8>) -> Result<(), RoomError>;
    /// 방이 정지했다(`reason` = 정책 거부 코드 또는 `history_gap`). 재시작 뒤에도 정지가 유지되게 저장한다.
    fn halted(&self, reason: String, detail: String, sync: RoomSyncState) -> Result<(), RoomError>;
}

/// host-core `Client` 가 호스트 전송을 쓰게 하는 어댑터(`MlsRoom`·`MlsLobby` 공용).
pub(crate) struct ForeignTransport(pub(crate) Arc<dyn HttpTransport>);

impl api::Transport for ForeignTransport {
    fn send(
        &self, base: &str, method: &str, path_qs: &str, body: Option<&[u8]>, extra_headers: &[(&str, &str)],
    ) -> Result<Response, RelayError> {
        let headers = extra_headers
            .iter()
            .map(|(name, value)| HttpHeader { name: (*name).to_string(), value: (*value).to_string() })
            .collect();
        let resp = self
            .0
            .send(method.to_string(), format!("{base}{path_qs}"), headers, body.map(<[u8]>::to_vec))
            .map_err(|e| RelayError::Http(HttpError::Io(std::io::Error::other(e.to_string()))))?;
        Ok(Response { status: resp.status, body: resp.body })
    }
}

/// 한 방 = 파사드 `Device` 하나 + 동기화 위치. 메서드는 `&self`, 내부 Mutex 로 직렬화(uniffi Object 는 Send+Sync).
#[derive(uniffi::Object)]
pub struct MlsRoom {
    identity: String,
    inner: Mutex<Inner>,
}

struct Inner {
    device: Device,
    sync: RoomSync,
    sends: u64,
    /// 409 cas_mismatch 로 밀린 평문(시도 횟수와 함께) — 다음 poll 뒤 순서대로 다시 보낸다.
    retry: VecDeque<(Vec<u8>, u32)>,
    client: Client,
    observer: Arc<dyn RoomObserver>,
}

/// 재시도 상한(봇 `MAX_ECHO_ATTEMPTS` 와 같음).
const MAX_SEND_ATTEMPTS: u32 = 8;

fn snapshot_state(inner: &Inner) -> RoomSyncState {
    let s = &inner.sync;
    RoomSyncState {
        room: s.room.clone(), cursor: s.cursor, epoch: s.epoch, joined: s.joined, joinable: s.joinable,
        acked: s.acked, ack_sent: s.ack_sent, ack_disabled: s.ack_disabled, halted: s.halted, sends: inner.sends,
    }
}

fn require_identifier(what: &str, s: &str) -> Result<(), RoomError> {
    if api::is_identifier(s) { Ok(()) } else { Err(RoomError::Host { reason: format!("invalid {what}: {s:?}") }) }
}

#[uniffi::export]
impl MlsRoom {
    /// 새 신원·새 방(그룹은 아직 없다 — `dispatch("create")` 또는 Welcome `poll`).
    #[uniffi::constructor]
    pub fn new(
        identity: String, room: String, base_url: String, transport: Arc<dyn HttpTransport>, observer: Arc<dyn RoomObserver>,
    ) -> Result<Arc<Self>, RoomError> {
        require_identifier("identity", &identity)?;
        require_identifier("room", &room)?;
        let device = Device::new(&identity).map_err(|e| mls_err(rejected(e)))?;
        let sync = RoomSync { room, joinable: true, ..RoomSync::default() };
        Ok(Self::assemble(identity, device, sync, 0, base_url, transport, observer))
    }

    /// 영속된 상태로 복원(`RoomObserver::persist` 가 받은 두 값).
    #[uniffi::constructor]
    pub fn import(
        identity: String, room: String, state: Vec<u8>, sync: RoomSyncState, base_url: String,
        transport: Arc<dyn HttpTransport>, observer: Arc<dyn RoomObserver>,
    ) -> Result<Arc<Self>, RoomError> {
        require_identifier("identity", &identity)?;
        require_identifier("room", &room)?;
        if sync.room != room {
            return Err(RoomError::Host { reason: format!("sync state is for room {:?}, not {room:?}", sync.room) });
        }
        let device = Device::import_state(&identity, &state).map_err(|e| mls_err(rejected(e)))?;
        let restored = RoomSync {
            room, cursor: sync.cursor, epoch: sync.epoch, joined: sync.joined, joinable: sync.joinable, dirty: false,
            acked: sync.acked, ack_sent: sync.ack_sent, ack_disabled: sync.ack_disabled, halted: sync.halted,
        };
        Ok(Self::assemble(identity, device, restored, sync.sends, base_url, transport, observer))
    }

    /// 다른 기기 상태로 이 방을 **시작**한다(#366 3c, iOS `LobbyKeyring.adoptRoom` 과 같은 규칙). 두 용도:
    /// - 로비 시드(`MlsLobby::seed_state`)로 방을 새로 만들 때(`after` = 0) — 서명키가 로비·다른 방들과 같아야
    ///   릴레이 정책 체인(기기당 키 1개)과 어긋나지 않는다(`new` 는 새 서명키를 만든다).
    /// - 로비 key package 로 받은 Welcome(`MlsLobby::welcomes`)을 열 때 — 그 key package 의 비밀은 로비 상태에만 있으니
    ///   그 상태로 엔진을 만들고 커서를 Welcome 앞(`after` = `seq - 1`)에 둔다. 다음 `poll` 이 join 한다.
    ///
    /// 그룹은 아직 없다(`dispatch("create")` 또는 Welcome `poll`). 돌아오기 전에 `persist` 를 한 번 부른다 — 상태·동기화 쌍이
    /// 네트워크 전에 디스크에 있어야 한다(§4 불변식 3).
    #[uniffi::constructor]
    #[allow(clippy::too_many_arguments)]
    pub fn adopt(
        identity: String, room: String, state: Vec<u8>, after: i64, base_url: String,
        transport: Arc<dyn HttpTransport>, observer: Arc<dyn RoomObserver>,
    ) -> Result<Arc<Self>, RoomError> {
        require_identifier("identity", &identity)?;
        require_identifier("room", &room)?;
        if after < 0 {
            return Err(RoomError::Host { reason: format!("adopt: cursor {after} must not be negative") });
        }
        let device = Device::import_state(&identity, &state).map_err(|e| mls_err(rejected(e)))?;
        let sync = RoomSync { room, cursor: after, acked: after, ack_sent: after, joinable: true, ..RoomSync::default() };
        let adopted = Self::assemble(identity, device, sync, 0, base_url, transport, observer);
        {
            let mut inner = adopted.lock()?;
            let mut host = Host { inner: &mut inner, identity: &adopted.identity };
            room::SendHost::persist(&mut host).map_err(relay_err)?;
        }
        Ok(adopted)
    }

    pub fn identity(&self) -> String {
        self.identity.clone()
    }

    /// CF Access 토큰 교체(`None` = 인증 없음). 다음 요청부터 쓴다.
    pub fn set_access_token(&self, token: Option<String>) -> Result<(), RoomError> {
        let mut inner = self.lock()?;
        inner.client.set_access(match token { Some(t) => Access::Static(t), None => Access::None });
        Ok(())
    }

    /// `POST /v2/rooms/{room}/close`(§3.4 B1, #366 3c): 방을 닫는다 — 멤버 전원이 그 뒤 410 `room_closed` 를 읽는다.
    /// 참 = 닫혔다(이미 닫혀 있었어도), 거짓 = 릴레이에 그 방이 없다(첫 초대가 나가지 않은 로컬 방). 403 `not_a_member` 등은
    /// `Relay` 오류. 로컬 상태는 그대로 — 버리는 것은 호스트 몫.
    pub fn close_room(&self) -> Result<bool, RoomError> {
        let inner = self.lock()?;
        inner.client.close_room(&inner.sync.room, &self.identity).map_err(relay_err)
    }

    /// 동기화 한 바퀴(봇 `poll_room` 과 같은 순서). 상태가 움직였으면 끝에 영속한다.
    pub fn poll(&self) -> Result<(), RoomError> {
        let mut inner = self.lock()?;
        let mut host = Host { inner: &mut inner, identity: &self.identity };
        room::poll(&mut host, &self.identity).map_err(relay_err)?;
        if host.sync().dirty {
            room::SendHost::persist(&mut host).map_err(relay_err)?;
        }
        Ok(())
    }

    /// application 메시지 하나를 보낸다: 암호화 → dedup 키 예약 → 영속 → POST(review 2 B-H2).
    pub fn send(&self, plaintext: Vec<u8>) -> Result<SendResult, RoomError> {
        let mut inner = self.lock()?;
        let outcome = {
            let mut host = Host { inner: &mut inner, identity: &self.identity };
            room::send_application(&mut host, &self.identity, &plaintext).map_err(relay_err)?
        };
        Ok(match outcome {
            SendOutcome::Sent { client_id, response } => {
                SendResult::Sent { client_id, seq: response.seq, epoch: response.epoch, duplicate: response.duplicate }
            }
            SendOutcome::Conflict { client_id, .. } => {
                inner.retry.push_back((plaintext, 1));
                inner.observer.event(RoomEvent::Conflict { client_id: client_id.clone(), attempt: 1 });
                SendResult::Queued { client_id }
            }
            SendOutcome::AlreadyDelivered { client_id, .. } => SendResult::AlreadyDelivered { client_id },
        })
    }

    /// 이 기기가 만든 commit(`dispatch("invite_with_commit")`/`remove_pending`)을 올린다. merge 는 자기 echo 를
    /// `poll` 이 만날 때(`OwnCommitMerged`) — 그 뒤 초대라면 `post_welcome`.
    pub fn post_commit(&self, commit: Vec<u8>) -> Result<PostedEvent, RoomError> {
        self.post_kind("commit", commit, Vec::new())
    }

    /// Welcome 을 대상 기기들에게 올린다(릴레이가 대상에게만 보여 준다).
    pub fn post_welcome(&self, welcome: Vec<u8>, targets: Vec<String>) -> Result<PostedEvent, RoomError> {
        self.post_kind("welcome", welcome, targets)
    }

    /// 전체 그룹 상태(봉인은 호스트 몫 — Android Keystore + EncryptedFile).
    pub fn export_state(&self) -> Result<Vec<u8>, RoomError> {
        let inner = self.lock()?;
        inner.device.export_state(&self.identity).map_err(|e| mls_err(rejected(e)))
    }

    pub fn sync_state(&self) -> Result<RoomSyncState, RoomError> {
        let inner = self.lock()?;
        Ok(snapshot_state(&inner))
    }

    /// `MlsDevice::dispatch` 와 같은 진입점·같은 롤백(초대·key package·create 등). 성공하면 바로 영속한다 —
    /// 돌려받은 바이트(key package·commit·Welcome)가 릴레이로 나가기 전에 그 상태가 디스크에 있어야 한다.
    pub fn dispatch(&self, method: String, input: Vec<u8>) -> Result<Vec<u8>, MlsError> {
        let mut inner = self.lock().map_err(|e| MlsError::Invalid { reason: e.to_string() })?;
        let output = dispatch_guarded(&mut inner.device, &self.identity, &method, &input)?;
        // 방을 만들었거나(create) Welcome 으로 들어갔으면(join) 이제 멤버다 — 봇 steward 의 `create` 와 같다.
        if method == "create" || method == "join" {
            inner.sync.joined = true;
        }
        inner.sync.dirty = true;
        let mut host = Host { inner: &mut inner, identity: &self.identity };
        room::SendHost::persist(&mut host).map_err(|e| MlsError::Invalid { reason: format!("persist: {e}") })?;
        Ok(output)
    }
}

impl MlsRoom {
    #[allow(clippy::too_many_arguments)]
    fn assemble(
        identity: String, device: Device, sync: RoomSync, sends: u64, base_url: String,
        transport: Arc<dyn HttpTransport>, observer: Arc<dyn RoomObserver>,
    ) -> Arc<Self> {
        let client = Client::with_transport(&base_url, Access::None, Box::new(ForeignTransport(transport)));
        Arc::new(Self { identity, inner: Mutex::new(Inner { device, sync, sends, retry: VecDeque::new(), client, observer }) })
    }

    fn lock(&self) -> Result<MutexGuard<'_, Inner>, RoomError> {
        self.inner.lock().map_err(|_| RoomError::Host { reason: "room lock poisoned".into() })
    }

    fn post_kind(&self, kind: &str, bytes: Vec<u8>, targets: Vec<String>) -> Result<PostedEvent, RoomError> {
        let mut inner = self.lock()?;
        let mut host = Host { inner: &mut inner, identity: &self.identity };
        let client_id = room::SendHost::reserve_client_id(&mut host);
        host.sync().dirty = true;
        room::SendHost::persist(&mut host).map_err(relay_err)?;
        let (room, epoch) = (host.inner.sync.room.clone(), host.inner.sync.epoch);
        let post = EventPost {
            device: &self.identity, client_id: &client_id, kind, epoch, revision: None, group_id: &room,
            targets, members: Vec::new(), bytes,
        };
        let resp = host.inner.client.post_event(&room, &post).map_err(relay_err)?;
        Ok(PostedEvent { seq: resp.seq, epoch: resp.epoch, duplicate: resp.duplicate })
    }
}

// ---- host-core 쪽 어댑터 ----

/// 파사드 `Device` 를 host-core `MlsGroup` 으로(봇 `Bound` 와 같은 프레이밍).
pub(crate) struct Bound<'a> {
    dev: &'a mut Device,
    own: &'a str,
    room: &'a str,
}

impl room::MlsGroup for Bound<'_> {
    type Snapshot = Zeroizing<Vec<u8>>;
    fn snapshot(&self) -> Result<Self::Snapshot, ()> {
        self.dev.export_state(self.own).map(Zeroizing::new).map_err(drop)
    }
    fn restore(&mut self, snapshot: &Self::Snapshot) -> Result<(), ()> {
        *self.dev = Device::import_state(self.own, snapshot).map_err(drop)?;
        Ok(())
    }
    fn stage_commit(&mut self, commit: &[u8]) -> Result<Vec<u8>, ()> { self.dev.stage_commit(commit).map_err(drop) }
    fn merge_staged(&mut self) -> Result<(), ()> { self.dev.merge_staged().map_err(drop) }
    fn discard_staged(&mut self) { let _ = self.dev.discard_staged(); }
    fn members(&self) -> Result<Vec<u8>, ()> { self.dev.members().map_err(drop) }
    fn join(&mut self, welcome: &[u8]) -> Result<(), ()> { self.dev.join(welcome).map_err(drop) }
    fn decrypt(&mut self, ciphertext: &[u8]) -> Result<(Vec<u8>, Vec<u8>), ()> {
        decrypt_frame(self.dev, self.room, ciphertext)
    }
    fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, ()> {
        encrypt_frame(self.dev, self.room, self.own, plaintext)
    }
}

struct Host<'a> {
    inner: &'a mut Inner,
    identity: &'a str,
}

impl room::RoomAccess for Host<'_> {
    type Group<'g> = Bound<'g> where Self: 'g;
    fn sync(&mut self) -> &mut RoomSync { &mut self.inner.sync }
    fn group(&mut self) -> Bound<'_> {
        let inner = &mut *self.inner;
        Bound { dev: &mut inner.device, own: self.identity, room: &inner.sync.room }
    }
}

impl room::RoomHost for Host<'_> {
    fn fetch(&mut self, room: &str, after: i64, ack: Option<i64>) -> Result<api::EventsResponse, RelayError> {
        self.inner.client.get_events(room, self.identity, after, ack)
    }

    fn report(&mut self, event: SyncEvent<'_>) {
        let mapped = match event {
            SyncEvent::AckRefused { ack, status, code } => RoomEvent::AckRefused { ack, status, code: code.to_string() },
            SyncEvent::Joined { epoch, seq } => RoomEvent::Joined { epoch, seq },
            SyncEvent::WelcomeIgnored { seq, joined } => RoomEvent::WelcomeIgnored { seq, joined },
            SyncEvent::Rejected { seq, kind, bytes } => RoomEvent::Rejected { seq, kind: kind.to_string(), bytes: bytes as u64 },
            SyncEvent::CommitApplied { ev, report, members, outer_checked } => RoomEvent::CommitApplied {
                seq: ev.seq, committer: ev.device.clone(), epoch: ev.epoch + 1,
                adds: report.adds.iter().map(|m| m.id.clone()).collect(),
                removes: report.removes.iter().map(|m| m.id.clone()).collect(),
                members: members.to_vec(), outer_checked,
            },
            // 복호화된 본문은 `application` 콜백으로 간다 — 로그에는 길이만.
            SyncEvent::Application { .. } => return,
            SyncEvent::Undecryptable { seq, bytes } => RoomEvent::Undecryptable { seq, bytes: bytes as u64 },
        };
        self.inner.observer.event(mapped);
    }

    fn halt(&mut self, halt: Halt<'_>) -> Result<(), RelayError> {
        let (reason, detail) = match halt {
            Halt::Refused { ev, refusal } => {
                // 거부된 commit 은 버려졌고 epoch 는 그대로 — 그 사실(halted)이 상태와 함께 저장돼야 한다.
                self.inner.sync.dirty = true;
                (refusal.reason.to_string(), format!("seq {} committer {} epoch {} {}", ev.seq, ev.device, ev.epoch, refusal.detail))
            }
            Halt::Gap { first_seq, relay_epoch, from, to } => (
                "history_gap".to_string(),
                format!("after {} first_seq {first_seq} missing {from}..{to} epoch {} relay_epoch {relay_epoch}",
                        self.inner.sync.cursor, self.inner.sync.epoch),
            ),
        };
        let snapshot = snapshot_state(self.inner);
        self.inner.observer.halted(reason, detail, snapshot).map_err(host_err)
    }

    fn application(&mut self, ev: &StoredRow, sender: Vec<u8>, plaintext: Vec<u8>) -> Result<(), RelayError> {
        self.inner
            .observer
            .application(ev.seq, String::from_utf8_lossy(&sender).into_owned(), ev.client_id.clone(), plaintext)
            .map_err(host_err)
    }

    fn own_event(&mut self, ev: &StoredRow) -> Result<(), RelayError> {
        if ev.kind == "commit" && self.inner.device.has_pending() {
            // 이 기기가 올린 commit 이 돌아왔다: 여기서 merge 하고 epoch 를 옮긴다(봇 `own_commit_echo`).
            let outcome = room::guarded(&mut self.group(), |g| g.dev.merge_pending().map_err(drop))?;
            let event = match outcome {
                Ok(()) => {
                    self.inner.sync.epoch = ev.epoch + 1;
                    self.inner.sync.dirty = true;
                    RoomEvent::OwnCommitMerged { seq: ev.seq, epoch: ev.epoch + 1 }
                }
                Err(()) => RoomEvent::OwnCommitMergeRejected { seq: ev.seq },
            };
            self.inner.observer.event(event);
        } else {
            self.inner.observer.event(RoomEvent::OwnEvent { seq: ev.seq, kind: ev.kind.clone() });
        }
        Ok(())
    }

    /// 이 poll 전에 밀린 것만 다시 보낸다(봇과 같은 규칙): 또 거부되면 다음 poll 로, 한도를 넘기면 버린다.
    fn after_page(&mut self) -> Result<(), RelayError> {
        let own = self.identity;
        let due = std::mem::take(&mut self.inner.retry);
        for (plaintext, attempts) in due {
            if attempts >= MAX_SEND_ATTEMPTS {
                self.inner.observer.event(RoomEvent::Dropped {
                    bytes: plaintext.len() as u64, error: "send replay attempts exhausted".into(),
                });
                continue;
            }
            match room::send_application(self, own, &plaintext) {
                Ok(SendOutcome::Sent { client_id, response }) => self.inner.observer.event(RoomEvent::Replayed {
                    client_id, seq: response.seq, epoch: response.epoch,
                }),
                Ok(SendOutcome::Conflict { client_id, .. }) => {
                    self.inner.retry.push_back((plaintext, attempts + 1));
                    self.inner.observer.event(RoomEvent::Conflict { client_id, attempt: attempts + 1 });
                }
                Ok(SendOutcome::AlreadyDelivered { client_id, .. }) => {
                    self.inner.observer.event(RoomEvent::AlreadyDelivered { client_id });
                }
                Err(err) => {
                    self.inner.observer.event(RoomEvent::Dropped { bytes: plaintext.len() as u64, error: err.to_string() });
                    return Err(err);
                }
            }
        }
        Ok(())
    }
}

impl room::SendHost for Host<'_> {
    /// iOS 와 같은 모양 `<identity>-<8 hex>`; 카운터는 영속된다(`RoomSyncState::sends`).
    fn reserve_client_id(&mut self) -> String {
        self.inner.sends += 1;
        format!("{}-{:08x}", self.identity, self.inner.sends)
    }

    fn persist(&mut self) -> Result<(), RelayError> {
        let state = self.inner.device.export_state(self.identity).map_err(|_| RelayError::Local("state export rejected"))?;
        let snapshot = snapshot_state(self.inner);
        self.inner.observer.persist(state, snapshot).map_err(host_err)?;
        self.inner.sync.dirty = false;
        self.inner.sync.acked = self.inner.sync.cursor;
        Ok(())
    }

    fn post(&mut self, room: &str, post: &EventPost<'_>) -> Result<api::EventResponse, RelayError> {
        self.inner.client.post_event(room, post)
    }
}

// ---- 프레이밍(봇 session.rs 와 바이트 동일) ----

fn push_identity(out: &mut Vec<u8>, part: &[u8]) {
    out.extend_from_slice(&(part.len() as u32).to_le_bytes());
    out.extend_from_slice(part);
}

fn read_identity(bytes: &[u8], at: &mut usize) -> Option<Vec<u8>> {
    let end = at.checked_add(4)?;
    if bytes.len() < end { return None; }
    let len = u32::from_le_bytes(bytes[*at..end].try_into().ok()?) as usize;
    *at = end.checked_add(len)?;
    if bytes.len() < *at { return None; }
    Some(bytes[end..*at].to_vec())
}

/// encrypt 입력: `u32 LE room_len ‖ room ‖ u32 LE client_len ‖ client ‖ plaintext`.
fn encrypt_frame(device: &mut Device, room: &str, client_id: &str, plaintext: &[u8]) -> Result<Vec<u8>, ()> {
    let mut input = Vec::with_capacity(8 + room.len() + client_id.len() + plaintext.len());
    push_identity(&mut input, room.as_bytes());
    push_identity(&mut input, client_id.as_bytes());
    input.extend_from_slice(plaintext);
    device.encrypt(&input).map_err(drop)
}

/// decrypt 입력: `u32 LE room_len ‖ room ‖ ciphertext`; 출력(DECRYPT_FORMAT 2)에서 sender 와 평문을 꺼낸다.
fn decrypt_frame(device: &mut Device, room: &str, ciphertext: &[u8]) -> Result<(Vec<u8>, Vec<u8>), ()> {
    let mut input = Vec::with_capacity(4 + room.len() + ciphertext.len());
    push_identity(&mut input, room.as_bytes());
    input.extend_from_slice(ciphertext);
    let out = device.decrypt(&input).map_err(drop)?;
    let mut at = 0;
    let sender = read_identity(&out, &mut at).ok_or(())?;
    let _client = read_identity(&out, &mut at).ok_or(())?;
    Ok((sender, out[at..].to_vec()))
}
