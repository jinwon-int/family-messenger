//! #366 3c — 기기 수준(방 무관) 객체 `MlsLobby`: 로비 key package(#380 P5, iOS `LobbyKeyring` 과 같은 규칙) · 방 목록
//! (`GET /v2/rooms`) · 푸시 등록(`/v2/push/devices`). 와이어는 host-core `api::Client`(봇과 같은 코드), 전송은 `MlsRoom` 과
//! 같은 `HttpTransport`.
//!
//! 왜 방 밖에 있는가: 방별 key package 는 그 방 상태에만 비밀(init 키)이 있어 기기가 먼저 그 방에 「참여 요청」을 해야 초대받을 수
//! 있다. 로비(server/lobby.go)는 기기가 한 번 올려 두면 steward 봇이 어느 방에서든 소비(`consumed_room`)해 Welcome 을 보낸다.
//! 그 Welcome 을 열려면 **소비된 key package 의 비밀**이 그 방의 엔진 상태에 있어야 하므로, 비밀은 로비 상태 하나에 모아 두고
//! 새 방은 그 바이트로 시작한다(`MlsRoom::adopt`). 로비 상태의 서명키가 곧 이 기기의 서명키(등록 JSON `signing_key`)다 — 방들도
//! 전부 이 시드에서 시작해야 릴레이 정책 체인(기기당 키 1개)과 어긋나지 않는다.
//!
//! 보충 규칙(`replenish`): 릴레이는 가장 오래된 것부터 소비·만료(lobby.go `ORDER BY rowid`, 균일 TTL)하므로 서버 `live` 만 알면
//! 장부(`published`) 앞쪽 `published.len() - live` 개가 소비·만료된 것이다 — 그 로컬 비밀을 `delete_key_package` 로 지워
//! 파사드 상한(8)을 비우고, 부족분을 새로 만들어 게시한다. 비밀은 **게시 전에** 영속한다(persist-before-bytes-leave); 게시에
//! 실패한 새 key package 는 비밀을 바로 지운다(서버에 없는 키는 로컬 상한만 차지한다).
//!
//! 소비분의 비밀은 **그 키로 만든 Welcome 을 받아들이기 전에는 지우지 않는다**(#616, iOS `LobbyKeyring.replenish(protect:)` #518 과
//! 같은 뜻): 지우면 그 Welcome 은 영영 열 수 없고, 코어 `poll` 은 거부된 Welcome 을 지나가 버린다. 소비분 하나는 다음 순서로 판정한다 —
//! ① 릴레이가 그 ref 의 Welcome 이 아직 읽히지 않았다고 하면(`GET /v2/lobby/welcomes` `key_package_ref`) 남긴다
//! ② 그 Welcome 을 본 적이 있고 이제 목록에 없으면(읽고 지나감 = 참여 · 방이 닫힘 · 다시 초대됨) 지운다
//! ③ 본 적이 없으면 처음 소비분으로 본 때부터 [`CONSUMED_HOLD`] 동안 남긴다 — 소비(`GET /v2/lobby/keypackages`)와 Welcome 게시
//!    사이에는 틈이 있어, 그 사이에 돈 보충이 비밀을 지우던 것이 #616 의 실기기 증상이다. 그 뒤에는 주인 없는 소비분으로 보고 지운다.
//! 남긴 것은 장부 **앞쪽에 그대로** 둔다(FIFO 가 유지되어 다음 보충이 같은 것을 다시 판정한다). 남긴 비밀도 파사드 상한(8)을
//! 차지하므로 그동안은 그만큼 덜 만들어질 수 있다. ①②③ 의 기억(`held`)은 메모리에만 있다 — 재시작하면 ③ 의 시계가 다시 돈다.
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use family_mls_browser_experiment::Device;
use native_mls_host::api::{self, Access, Client};
use sha2::{Digest, Sha256};

use crate::room::{mls_err, relay_err, ForeignTransport, HttpTransport, RoomError};
use crate::{dispatch_guarded, hex, rejected, MlsError};

/// 로비 슬롯의 저장 형식(호스트가 통째로 봉인·영속; `import` 로 되돌린다).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct MlsLobbySlot {
    /// 파사드 `export_state`: 서명키 시드 + 로비 key package 비밀.
    pub state: Vec<u8>,
    /// 릴레이가 받은 key package 바이트(게시 순 = 릴레이 소비 순).
    pub published: Vec<Vec<u8>>,
}

/// `GET /v2/lobby/status` — 서버의 미소비 수와 정책 상한.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct MlsLobbyStatus {
    pub live: u32,
    pub max: u32,
    pub ttl_seconds: i64,
}

/// `watch` 입력 한 줄: 방 이름 + 이 기기가 그 방에서 이미 읽은 위치(`RoomSyncState.cursor`).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct MlsWatchRoom {
    pub room: String,
    pub after: i64,
}

/// `GET /v2/watch` 결과(#755 1단계). `supported = false` 는 릴레이가 #424 이전이라는 뜻 — 호스트는 고정 주기 폴링을 유지한다.
/// `changed` 는 행이 생겼거나 기다리는 동안 바뀐 방(새 글·typing·읽음·알림·닫힘), `refused` 는 릴레이가 기다리지 않은 방과 코드.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct MlsWatchResult {
    pub supported: bool,
    pub changed: Vec<String>,
    pub refused: Vec<MlsWatchRefusal>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct MlsWatchRefusal {
    pub room: String,
    pub code: String,
}

/// `replenish` 한 번의 결과(화면·테스트).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct MlsLobbyReport {
    /// 보충 뒤 서버의 미소비 수.
    pub live: u32,
    pub max: u32,
    pub minted: u32,
    /// 소비·만료된 것으로 판단해 로컬 비밀을 지운 수.
    pub pruned: u32,
    /// 소비·만료된 것으로 판단했지만 지우지 않고 장부 앞쪽에 남긴 수(#616 — 아직 참여하지 않은 Welcome 이 쓸 수 있다).
    pub kept: u32,
}

/// 이 기기가 아직 읽지 않은 Welcome 을 들고 있는 방(`GET /v2/lobby/welcomes`). `MlsRoom::adopt(…, seq - 1, …)` 로 받아들인다.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct MlsLobbyWelcome {
    pub room: String,
    pub seq: i64,
    pub epoch: i64,
    pub created_at: i64,
    /// Welcome 을 올린 기기(#574) — 같은 actor 의 활성 형제 기기면 묻지 않고 받아들인다(`/v2/me` 로 판정). 옛 릴레이는 빈값.
    pub from: String,
    /// 이 Welcome 을 만든 로비 key package 의 ref(#380, sha256 hex). 방 패키지로 만든 것·옛 릴레이는 빈값.
    pub key_package_ref: String,
}

// ---- #574 기기 셀프서비스(devices.go · me.go) — 와이어는 host-core `api::Client`, 서명은 파사드 `policy_wire` ----

/// `/v2/me` 의 내 subject 기기 기록 하나(공개 필드만, 서명키 없음).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct MlsMeDevice {
    pub device_id: String,
    pub actor: String,
    pub fingerprint: String,
    /// `active` | `revoked`.
    pub status: String,
    pub acceptance: String,
    /// 정렬된 역할 목록 — 오늘은 `registrar` 하나.
    pub roles: Vec<String>,
}

/// `GET /v2/me`: 검증된 JWT subject + (기기 저장소가 있는 릴레이) 정책 revision 과 내 기기 전부. 옛 릴레이는 `{subject}` 만 —
/// 그때 `policy_revision` 은 없음, `devices` 는 빈 목록.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct MlsMe {
    pub subject: String,
    pub policy_revision: Option<u64>,
    pub devices: Vec<MlsMeDevice>,
}

/// 우편함의 후보 하나(`GET /v2/devices/candidates`): 새 기기가 올린 공개 기록.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct MlsCandidate {
    pub device_id: String,
    pub actor: String,
    pub subject: String,
    /// Ed25519 공개키 lowercase hex(64자).
    pub signing_key: String,
    /// 릴레이가 계산한 sha256(공개키) — 승인 전에 로컬 `policy_fingerprint` 로 다시 계산해 대조한다.
    pub fingerprint: String,
    pub created_at: i64,
    /// unix 초. 10분 TTL.
    pub expires_at: i64,
}

/// 셀프서비스 라우트의 거절(값으로 — 다음 행동은 상태코드·코드로 정한다). `code`·`detail` 은 봉투가 아니면(옛 릴레이의 bare 404) 빈값,
/// `revision` 은 409 `stale_revision` 의 현재 revision.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct MlsRefusal {
    pub status: u16,
    pub code: String,
    pub detail: String,
    pub revision: Option<i64>,
}

/// `POST /v2/devices/candidates` 의 결과: 201 = 형제 기기의 승인을 기다린다(`expires_at` 5분 전에 다시 올린다) ·
/// 409 `device_exists` = 이 ID 는 다시 쓸 수 없다 · 403 `first_device_out_of_band`/404(옛 릴레이) = 운영자 흐름.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum MlsCandidatePost {
    Posted { fingerprint: String, policy_revision: u64, expires_at: i64 },
    Refused { refusal: MlsRefusal },
}

/// `GET /v2/devices/candidates?device=` 의 결과. `policy_revision` 이 승인 서명의 `base_revision`.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum MlsCandidateList {
    Listed { policy_revision: u64, candidates: Vec<MlsCandidate> },
    Refused { refusal: MlsRefusal },
}

/// 승인(E2)·역할(E5) commit 의 결과: 201 = 체인 revision 이 올랐다 · 409 `stale_revision`(`refusal.revision` 으로 다시 서명) ·
/// 403 `approval_rejected`(`refusal.detail` 에 이유) · 403 `device_subject_mismatch`.
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum MlsPolicyCommit {
    Committed { device_id: String, approved_by: String, revision: u64, roles: Vec<String> },
    Refused { refusal: MlsRefusal },
}

/// `dispatch` 가 로비(기기 수준) 객체에서 받는 메서드 — 파사드 `policy_wire` 의 서명·지문 셋. 그룹·key package 연산은
/// 방(`MlsRoom::dispatch`)·보충(`replenish`)의 몫이라 여기서는 거부한다.
pub const LOBBY_METHODS: &[&str] = &["policy_fingerprint", "sign_approval", "sign_roles"];

/// 승인 서명의 고정 값(DEVICES-V4 E2): 파사드가 `approve-device` 에 허용하는 유일한 acceptance.
pub const APPROVAL_ACCEPTANCE: &str = "trusted-device-fingerprint";

fn refusal(r: api::Refusal) -> MlsRefusal {
    MlsRefusal { status: r.status, code: r.code, detail: r.detail, revision: r.revision }
}

/// 파사드 `frame_evidence`(`u32le n ‖ canonical ‖ 64B 서명`) → 서명 lowercase hex(웹 `device.js signatureOf` 와 같은 추출).
pub(crate) fn signature_hex(framed: &[u8]) -> Result<String, RoomError> {
    let bad = || RoomError::Mls { reason: "evidence frame".into() };
    if framed.len() < 4 { return Err(bad()); }
    let n = u32::from_le_bytes(framed[0..4].try_into().map_err(|_| bad())?) as usize;
    if framed.len() != 4 + n + 64 { return Err(bad()); }
    Ok(framed[4 + n..].iter().map(|b| format!("{b:02x}")).collect())
}

/// JSON 문자열 리터럴(RFC 8259 §7: `"`·`\`·제어문자만 이스케이프). 식별자·hex 는 식별자 문자집합이라 그대로지만 `subject` 는 임의의
/// 문자열(이메일·UUID)이라 안전하게 — 파사드가 어차피 `deny_unknown_fields` JSON 으로 다시 검증한다. serde_json 은 이 크레이트의
/// dev 의존이라 손으로 쓴다.
fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// 이 기기가 참여하는 방 하나(`GET /v2/rooms`): 공개 필드만.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct MlsRoomListing {
    pub room: String,
    pub epoch: i64,
    pub revision: i64,
    pub member: bool,
    pub keypackages_outstanding: u32,
    pub closed: bool,
}

/// 로비 관찰자(호스트 구현): 슬롯 원자 영속. 돌아오기 전에는 key package 가 릴레이로 나가지 않는다.
#[uniffi::export(foreign)]
pub trait LobbyObserver: Send + Sync {
    fn persist(&self, slot: MlsLobbySlot) -> Result<(), RoomError>;
}

/// 기기 하나 = 로비 파사드 `Device` 하나 + 게시 장부. 메서드는 `&self`, 내부 Mutex 로 직렬화.
#[derive(uniffi::Object)]
pub struct MlsLobby {
    identity: String,
    inner: Mutex<Inner>,
    /// `watch`(#755) 재료 — `inner` 잠금 밖. 호출마다 클라이언트를 새로 만들어, 대기(최대 수십 초) 동안 어떤 잠금도 잡지 않는다
    /// (`set_access_token` 도 막히지 않는다). 토큰은 `set_access_token` 이 `inner` 와 함께 바꾼다.
    watch_base: String,
    watch_transport: Arc<dyn HttpTransport>,
    watch_token: Mutex<Option<String>>,
}

/// 소비됐지만 Welcome 을 아직 보지 못한 key package 의 비밀을 남겨 두는 시간(#616). 봇·형제 기기가 로비 키를 소비한 뒤 commit 과
/// Welcome 을 올리기까지의 틈(재시도 포함)을 덮는다. Welcome 이 목록에 뜬 뒤에는 시간과 상관없이 참여할 때까지 남긴다.
pub const CONSUMED_HOLD: Duration = Duration::from_secs(10 * 60);

/// 소비분 하나의 기억(#616, 메모리만): 처음 소비분으로 본 때와, 그 ref 의 Welcome 을 대기 목록에서 본 적이 있는지.
struct Held {
    since: Instant,
    seen_waiting: bool,
}

struct Inner {
    device: Device,
    published: Vec<Vec<u8>>,
    client: Client,
    observer: Arc<dyn LobbyObserver>,
    /// 소비분의 ref → 기억. 장부에서 빠지면(지움·회수) 같이 지운다.
    held: HashMap<String, Held>,
    hold: Duration,
}

fn require_identifier(what: &str, s: &str) -> Result<(), RoomError> {
    if api::is_identifier(s) { Ok(()) } else { Err(RoomError::Host { reason: format!("invalid {what}: {s:?}") }) }
}

#[uniffi::export]
impl MlsLobby {
    /// 새 기기 신원(서명키는 파사드 안에서 생성). 돌아오기 전에 `persist` 를 한 번 부른다 — 시드가 디스크에 있어야 방을 만들 수 있다.
    #[uniffi::constructor]
    pub fn new(
        identity: String, base_url: String, transport: Arc<dyn HttpTransport>, observer: Arc<dyn LobbyObserver>,
    ) -> Result<Arc<Self>, RoomError> {
        require_identifier("identity", &identity)?;
        let device = Device::new(&identity).map_err(|e| mls_err(rejected(e)))?;
        let lobby = Self::assemble(identity, device, Vec::new(), base_url, transport, observer);
        {
            let mut inner = lobby.lock()?;
            lobby.persist(&mut inner)?;
        }
        Ok(lobby)
    }

    /// 영속된 슬롯으로 복원(`LobbyObserver::persist` 가 받은 값).
    #[uniffi::constructor]
    pub fn import(
        identity: String, slot: MlsLobbySlot, base_url: String, transport: Arc<dyn HttpTransport>, observer: Arc<dyn LobbyObserver>,
    ) -> Result<Arc<Self>, RoomError> {
        require_identifier("identity", &identity)?;
        let device = Device::import_state(&identity, &slot.state).map_err(|e| mls_err(rejected(e)))?;
        Ok(Self::assemble(identity, device, slot.published, base_url, transport, observer))
    }

    pub fn identity(&self) -> String {
        self.identity.clone()
    }

    /// CF Access 토큰 교체(`None` = 인증 없음). 다음 요청부터 쓴다.
    pub fn set_access_token(&self, token: Option<String>) -> Result<(), RoomError> {
        let mut inner = self.lock()?;
        inner.client.set_access(match token.clone() { Some(t) => Access::Static(t), None => Access::None });
        *self.watch_token.lock().map_err(|_| RoomError::Host { reason: "watch token lock poisoned".into() })? = token;
        Ok(())
    }

    /// 로비 상태 바이트 — `MlsRoom::adopt` 의 `state`(방을 만들 때 `after` = 0, Welcome 을 받아들일 때 `seq - 1`).
    pub fn seed_state(&self) -> Result<Vec<u8>, RoomError> {
        let inner = self.lock()?;
        inner.device.export_state(&self.identity).map_err(|e| mls_err(rejected(e)))
    }

    /// 지금 슬롯의 스냅샷(디버그·백업 — 영속의 정본은 `persist` 콜백).
    pub fn slot(&self) -> Result<MlsLobbySlot, RoomError> {
        let inner = self.lock()?;
        Ok(Self::snapshot(&self.identity, &inner)?)
    }

    /// 장부에 있는(릴레이가 받은) key package 수 — 화면용.
    pub fn published_count(&self) -> Result<u32, RoomError> {
        Ok(self.lock()?.published.len() as u32)
    }

    /// Ed25519 서명 공개키 원본 바이트(등록 JSON `signing_key` = lowercase hex). 방들이 이 시드에서 시작하면 같은 키다.
    pub fn public_key(&self) -> Result<Vec<u8>, RoomError> {
        let mut inner = self.lock()?;
        inner.device.public_key().map_err(|e| mls_err(rejected(e)))
    }

    /// `GET /v2/lobby/status?device=`. 옛 릴레이(로비 없음)는 404 를 `Relay{transient: false}` 로 돌려준다 — 호스트가 "로비 없음" 으로 건너뛴다.
    pub fn status(&self) -> Result<MlsLobbyStatus, RoomError> {
        let inner = self.lock()?;
        let status = inner.client.lobby_status(&self.identity).map_err(relay_err)?;
        Ok(MlsLobbyStatus { live: status.live as u32, max: status.max as u32, ttl_seconds: status.ttl_seconds })
    }

    /// 서버의 미소비 수가 `min(target, 서버 max)` 보다 적으면 그만큼 만들어 게시한다. 먼저 장부 앞쪽(소비·만료분)의 로컬 비밀을
    /// 지운다 — 단, 아직 참여하지 않은 Welcome 이 쓸 수 있는 것은 남긴다(모듈 주석 ①②③, `kept`). 파사드 상한(8)에 닿으면 거기서
    /// 멈춘다(오류 아님). 앱은 시작·포그라운드·방 참여 뒤에 부른다(iOS 와 같은 시점).
    pub fn replenish(&self, target: u32) -> Result<MlsLobbyReport, RoomError> {
        let mut inner = self.lock()?;
        let status = inner.client.lobby_status(&self.identity).map_err(relay_err)?;
        let goal = (target as u64).min(status.max) as usize;
        let live = status.live as usize;

        // ① 소비·만료분의 로컬 비밀 — 아직 참여하지 않은 Welcome 이 쓸 수 있는 것은 장부 앞쪽에 남긴다(#616). 지우는 것은 이미
        //    없는(모르는) 비밀이어도 장부에서는 뺀다.
        let consumed = inner.published.len().saturating_sub(live);
        let waiting = if consumed > 0 { Self::waiting_refs(&mut inner, &self.identity)? } else { HashSet::new() };
        let now = Instant::now();
        let mut pruned = 0u32;
        let Inner { device, published, held, hold, .. } = &mut *inner;
        let mut kept: Vec<Vec<u8>> = Vec::new();
        for bytes in published.drain(..consumed) {
            let key_ref = api::ref_hex(&bytes);
            let memory = held.entry(key_ref.clone()).or_insert(Held { since: now, seen_waiting: false });
            let keep = waiting.contains(&key_ref) || (!memory.seen_waiting && now.duration_since(memory.since) < *hold);
            if keep {
                kept.push(bytes);
                continue;
            }
            held.remove(&key_ref);
            if dispatch_guarded(device, &self.identity, "delete_key_package", &bytes).is_ok() {
                pruned += 1;
            }
        }
        let kept_count = kept.len() as u32;
        published.splice(0..0, kept);
        // 장부에 없는 ref 의 기억은 버린다(이미 지워진 키를 가리키는 오래된 대기 Welcome 이 `held` 에 쌓이지 않게).
        let ledger: HashSet<String> = published.iter().map(|bytes| api::ref_hex(bytes)).collect();
        held.retain(|key_ref, _| ledger.contains(key_ref));
        // ② 부족분 — 파사드가 "key package limit" 으로 거부하면 멈춘다.
        let mut fresh: Vec<Vec<u8>> = Vec::new();
        let mut want = goal.saturating_sub(live);
        while want > 0 {
            match dispatch_guarded(device, &self.identity, "key_package", &[]) {
                Ok(kp) => fresh.push(kp),
                Err(MlsError::Rejected { reason }) if reason == "key package limit" => break,
                Err(e) => return Err(mls_err(e)),
            }
            want -= 1;
        }
        // ③ 비밀이 먼저 디스크에(persist-before-bytes-leave).
        self.persist(&mut inner)?;
        if fresh.is_empty() {
            return Ok(MlsLobbyReport { live: status.live as u32, max: status.max as u32, minted: 0, pruned, kept: kept_count });
        }
        // ④ 게시. 실패하면 서버가 받지 않은 키의 비밀은 버린다 — 다음 보충이 다시 만든다.
        let refs: Vec<(String, Vec<u8>)> = fresh.iter().map(|kp| (api::ref_hex(kp), kp.clone())).collect();
        let borrowed: Vec<(&str, Vec<u8>)> = refs.iter().map(|(r, kp)| (r.as_str(), kp.clone())).collect();
        match inner.client.post_lobby_key_packages(&self.identity, &borrowed) {
            Ok(stored) => {
                inner.published.extend(fresh.iter().cloned());
                self.persist(&mut inner)?;
                Ok(MlsLobbyReport { live: stored.live as u32, max: status.max as u32, minted: fresh.len() as u32, pruned, kept: kept_count })
            }
            Err(err) => {
                let Inner { device, .. } = &mut *inner;
                for kp in &fresh {
                    let _ = dispatch_guarded(device, &self.identity, "delete_key_package", kp);
                }
                self.persist(&mut inner)?;
                Err(relay_err(err))
            }
        }
    }

    /// `GET /v2/lobby/welcomes?device=`: 아직 읽지 않은 Welcome 이 있는 방들. 모르는 방이면 `MlsRoom::adopt(…, seed_state(), seq - 1, …)`
    /// 뒤 `poll` 이 join 한다; 이미 멤버인 방이면 그 방의 `poll` 이 알아서 넘어간다(`WelcomeIgnored`).
    ///
    /// 목록에 뜬 `key_package_ref` 는 기억해 둔다(#616): 그 Welcome 을 읽고 지나가 목록에서 빠지면 다음 `replenish` 가 그 비밀을 바로 지운다.
    pub fn welcomes(&self) -> Result<Vec<MlsLobbyWelcome>, RoomError> {
        let mut inner = self.lock()?;
        let list = inner.client.lobby_welcomes(&self.identity).map_err(relay_err)?;
        Self::note_waiting(&mut inner, list.iter().map(|w| w.key_package_ref.as_str()));
        Ok(list
            .into_iter()
            .map(|w| MlsLobbyWelcome {
                room: w.room, seq: w.seq, epoch: w.epoch, created_at: w.created_at, from: w.from, key_package_ref: w.key_package_ref,
            })
            .collect())
    }

    /// #875: **다른** 기기(같은 subject 의 형제 기기)를 대상으로 한, 그 기기의 durable cursor 가 아직 지나지 않은 Welcome
    /// (`GET /v2/lobby/welcomes?device=`, 릴레이 `bindDevice` 는 같은 subject 의 활성 기기를 허용). 읽기 전용 — 이 기기의
    /// 로비 키 기록(`welcomes` 의 `note_waiting`)은 건드리지 않는다. `created_at` 은 초.
    pub fn welcomes_for(&self, device: String) -> Result<Vec<MlsLobbyWelcome>, RoomError> {
        require_identifier("device", &device)?;
        let inner = self.lock()?;
        let list = inner.client.lobby_welcomes(&device).map_err(relay_err)?;
        Ok(list
            .into_iter()
            .map(|w| MlsLobbyWelcome {
                room: w.room, seq: w.seq, epoch: w.epoch, created_at: w.created_at, from: w.from, key_package_ref: w.key_package_ref,
            })
            .collect())
    }

    // ---- #574 기기 셀프서비스 ----

    /// `GET /v2/me`: 검증된 subject(등록 JSON 의 `subject`)·정책 revision·내 기기 전부. 401 → 세션 필요, 403 → (엣지) 허용되지
    /// 않은 신원, 봉투 없는 404 → 호출자 인증이 꺼진 릴레이(셀프서비스 없음) — 모두 `Relay` 오류로 호스트가 가른다.
    pub fn me(&self) -> Result<MlsMe, RoomError> {
        let inner = self.lock()?;
        let me = inner.client.get_me().map_err(relay_err)?;
        Ok(MlsMe {
            subject: me.subject,
            policy_revision: me.policy_revision,
            devices: me
                .devices
                .into_iter()
                .map(|d| MlsMeDevice {
                    device_id: d.device_id, actor: d.actor, fingerprint: d.fingerprint, status: d.status, acceptance: d.acceptance, roles: d.roles,
                })
                .collect(),
        })
    }

    /// `POST /v2/devices/candidates`: 아직 체인에 없는 이 기기가 자기 공개 기록(`device_id`·actor·서명 공개키 hex·지문)을 우편함에
    /// 올린다 — subject 는 보내지 않는다(릴레이가 JWT 에서). 같은 ID 재게시는 갱신(TTL 10분).
    pub fn post_candidate(&self) -> Result<MlsCandidatePost, RoomError> {
        let mut inner = self.lock()?;
        let key = inner.device.public_key().map_err(|e| mls_err(rejected(e)))?;
        let signing_key = hex(&key);
        let fingerprint = hex(&Sha256::digest(&key));
        let actor = self.identity.split('-').next().unwrap_or(&self.identity).to_owned();
        match inner.client.post_candidate(&self.identity, &actor, &signing_key, &fingerprint).map_err(relay_err)? {
            api::Answer::Ok(p) => Ok(MlsCandidatePost::Posted { fingerprint: p.fingerprint, policy_revision: p.policy_revision, expires_at: p.expires_at }),
            api::Answer::Refused(r) => Ok(MlsCandidatePost::Refused { refusal: refusal(r) }),
        }
    }

    /// `GET /v2/devices/candidates?device=<나>`: 내 subject 의 우편함(활성 기기만 볼 수 있다 — 403 은 `Refused`).
    pub fn list_candidates(&self) -> Result<MlsCandidateList, RoomError> {
        let inner = self.lock()?;
        match inner.client.list_candidates(&self.identity).map_err(relay_err)? {
            api::Answer::Ok(list) => Ok(MlsCandidateList::Listed {
                policy_revision: list.policy_revision,
                candidates: list
                    .candidates
                    .into_iter()
                    .map(|c| MlsCandidate {
                        device_id: c.device_id, actor: c.actor, subject: c.subject, signing_key: c.signing_key, fingerprint: c.fingerprint,
                        created_at: c.created_at, expires_at: c.expires_at,
                    })
                    .collect(),
            }),
            api::Answer::Refused(r) => Ok(MlsCandidateList::Refused { refusal: refusal(r) }),
        }
    }

    /// 후보 승인(E2, 웹 `app.js approveViaRelay` 와 같은 순서): ① 후보 공개키로 지문을 **로컬에서 다시 계산**(`policy_fingerprint`)해
    /// 릴레이가 전한 지문과 다르면 `Mls` 오류로 거부 ② `sign_approval` `{action:"approve-device", …, acceptance, base_revision}`
    /// ③ `POST /v2/devices/approvals`. 409 `stale_revision` 은 `Refused`(`refusal.revision` 으로 호스트가 한 번 다시 부른다).
    /// 사람의 대역외 지문 비교는 이 호출 **앞** 에서 호스트 화면이 한다.
    pub fn approve(&self, candidate: MlsCandidate, base_revision: u64) -> Result<MlsPolicyCommit, RoomError> {
        let mut inner = self.lock()?;
        let Inner { device, client, .. } = &mut *inner;
        let computed = dispatch_guarded(device, &self.identity, "policy_fingerprint", candidate.signing_key.as_bytes()).map_err(mls_err)?;
        if computed != candidate.fingerprint.as_bytes() {
            return Err(RoomError::Mls { reason: "candidate fingerprint mismatch".into() });
        }
        let args = format!(
            "{{\"action\":\"approve-device\",\"device_id\":{},\"actor\":{},\"subject\":{},\"signing_key\":{},\"acceptance\":\"{APPROVAL_ACCEPTANCE}\",\"base_revision\":{base_revision}}}",
            json_str(&candidate.device_id), json_str(&candidate.actor), json_str(&candidate.subject), json_str(&candidate.signing_key),
        );
        let framed = dispatch_guarded(device, &self.identity, "sign_approval", args.as_bytes()).map_err(mls_err)?;
        let evidence = api::ApprovalEvidence {
            device_id: candidate.device_id, actor: candidate.actor, subject: candidate.subject, signing_key: candidate.signing_key,
            base_revision, signature: signature_hex(&framed)?, fingerprint: candidate.fingerprint, approved_by: self.identity.clone(),
        };
        Self::committed(client.post_approval(&evidence).map_err(relay_err)?)
    }

    /// 역할 변경(E5): `roles` 는 대상이 최종적으로 갖는 **완전한** 목록(정렬·중복 제거는 여기서). `sign_roles` → `POST /v2/devices/roles`.
    /// 409 `stale_revision` 은 `Refused` — 호스트가 `/v2/me` 를 다시 읽고(대상의 역할도 움직였을 수 있다) 한 번 다시 부른다.
    pub fn set_roles(&self, device_id: String, actor: String, roles: Vec<String>, base_revision: u64) -> Result<MlsPolicyCommit, RoomError> {
        let mut sorted = roles;
        sorted.sort();
        sorted.dedup();
        let mut inner = self.lock()?;
        let Inner { device, client, .. } = &mut *inner;
        let roles_json: Vec<String> = sorted.iter().map(|r| json_str(r)).collect();
        let args = format!(
            "{{\"device_id\":{},\"actor\":{},\"roles\":[{}],\"base_revision\":{base_revision}}}",
            json_str(&device_id), json_str(&actor), roles_json.join(","),
        );
        let framed = dispatch_guarded(device, &self.identity, "sign_roles", args.as_bytes()).map_err(mls_err)?;
        let evidence = api::RolesEvidence {
            device_id, actor, roles: sorted, base_revision, signature: signature_hex(&framed)?, approved_by: self.identity.clone(),
        };
        Self::committed(client.post_roles(&evidence).map_err(relay_err)?)
    }

    /// 파사드 정책 메서드(`policy_fingerprint`·`sign_approval`·`sign_roles`)를 기기 서명키로 직접 부른다 — `MlsDevice::dispatch` 와
    /// 같은 바이트 규칙(`policy_wire`). 그 밖의 메서드는 `Invalid`(그룹·key package 연산은 방·`replenish` 의 몫).
    pub fn dispatch(&self, method: String, input: Vec<u8>) -> Result<Vec<u8>, MlsError> {
        if !LOBBY_METHODS.contains(&method.as_str()) {
            return Err(MlsError::Invalid { reason: format!("not a lobby method: {method}") });
        }
        let mut inner = self.lock().map_err(|e| MlsError::Invalid { reason: e.to_string() })?;
        dispatch_guarded(&mut inner.device, &self.identity, &method, &input)
    }

    /// `DELETE /v2/lobby/keypackages?device=`(#389, 「이 기기 지우기」 직전): 미소비 로비 키를 거두고 그 비밀도 지운다. 거둔 개수.
    pub fn withdraw(&self) -> Result<u64, RoomError> {
        let mut inner = self.lock()?;
        let deleted = inner.client.delete_lobby_key_packages(&self.identity).map_err(relay_err)?;
        let Inner { device, published, held, .. } = &mut *inner;
        for bytes in published.drain(..) {
            let _ = dispatch_guarded(device, &self.identity, "delete_key_package", &bytes);
        }
        held.clear();
        self.persist(&mut inner)?;
        Ok(deleted)
    }

    /// `GET /v2/rooms?device=`: 이 기기가 참여하는 방 목록(공개 필드만).
    pub fn rooms(&self) -> Result<Vec<MlsRoomListing>, RoomError> {
        let inner = self.lock()?;
        let list = inner.client.list_rooms(&self.identity).map_err(relay_err)?;
        Ok(list
            .into_iter()
            .map(|r| MlsRoomListing {
                room: r.room, epoch: r.epoch, revision: r.revision, member: r.member,
                keypackages_outstanding: r.keypackages_outstanding as u32, closed: r.closed,
            })
            .collect())
    }

    /// `POST /v2/push/devices`: 푸시 토큰 등록(`topic` = 앱 패키지/번들 id). 와이어 필드는 오늘 `apns_token` — FCM 일반화는
    /// 릴레이 변경(#338 G3)이고 이 호출 모양은 그대로다.
    pub fn register_push(&self, token: Vec<u8>, topic: String) -> Result<(), RoomError> {
        let inner = self.lock()?;
        inner.client.register_push(&self.identity, &token, &topic).map_err(relay_err)
    }

    /// `DELETE /v2/push/devices?device=`: 이 기기의 토큰을 전부 지운다.
    pub fn unregister_push(&self) -> Result<(), RoomError> {
        let inner = self.lock()?;
        inner.client.unregister_push(&self.identity).map_err(relay_err)
    }

    /// `GET /v2/watch`(#755 1단계): 여러 방을 요청 하나로 기다린다 — 이미 행이 있는 방이 있으면 즉시, 없으면 처음 바뀐 방들 또는
    /// `wait_ms` 뒤 빈 결과. **잠금을 잡지 않는다**(전용 `watcher`), 그래서 호스트가 작업 스레드를 여기 묶어 두어도 보내기·로비 조작은
    /// 그대로 간다. 대기는 호스트 HTTP 읽기 타임아웃보다 짧게(Android OkHttp read 15 s → 12 s). 릴레이가 #424 이전이면
    /// `supported = false` 로 즉시 돌아온다.
    pub fn watch(&self, rooms: Vec<MlsWatchRoom>, wait_ms: u32) -> Result<MlsWatchResult, RoomError> {
        let token = self.watch_token.lock().map_err(|_| RoomError::Host { reason: "watch token lock poisoned".into() })?.clone();
        let access = match token { Some(t) => Access::Static(t), None => Access::None };
        let client = Client::with_transport(&self.watch_base, access, Box::new(ForeignTransport(self.watch_transport.clone())));
        let pairs: Vec<(&str, i64)> = rooms.iter().map(|r| (r.room.as_str(), r.after)).collect();
        match client.watch(&self.identity, &pairs, wait_ms).map_err(relay_err)? {
            None => Ok(MlsWatchResult { supported: false, changed: Vec::new(), refused: Vec::new() }),
            Some(w) => Ok(MlsWatchResult {
                supported: true,
                changed: w.changed,
                refused: w.errors.into_iter().map(|(room, code)| MlsWatchRefusal { room, code }).collect(),
            }),
        }
    }
}

impl MlsLobby {
    fn assemble(
        identity: String, device: Device, published: Vec<Vec<u8>>, base_url: String, transport: Arc<dyn HttpTransport>,
        observer: Arc<dyn LobbyObserver>,
    ) -> Arc<Self> {
        let client = Client::with_transport(&base_url, Access::None, Box::new(ForeignTransport(transport.clone())));
        Arc::new(Self {
            identity,
            inner: Mutex::new(Inner { device, published, client, observer, held: HashMap::new(), hold: CONSUMED_HOLD }),
            watch_base: base_url,
            watch_transport: transport,
            watch_token: Mutex::new(None),
        })
    }

    fn lock(&self) -> Result<MutexGuard<'_, Inner>, RoomError> {
        self.inner.lock().map_err(|_| RoomError::Host { reason: "lobby lock poisoned".into() })
    }

    /// 소비됐지만 Welcome 을 보지 못한 비밀을 남겨 두는 시간을 바꾼다(기본 [`CONSUMED_HOLD`]). 바인딩에는 내보내지 않는다 — 호스트
    /// 게이트(`tests/lobby_host.rs`)가 시계를 기다리지 않고 「주인 없는 소비분」 정리를 보려고 쓴다.
    pub fn set_consumed_hold(&self, hold: Duration) -> Result<(), RoomError> {
        self.lock()?.hold = hold;
        Ok(())
    }

    /// 대기 목록에 뜬 ref 를 기억한다(빈 ref = 방 패키지로 만든 Welcome · 옛 릴레이 → 모름, 건너뛴다).
    fn note_waiting<'a>(inner: &mut Inner, refs: impl Iterator<Item = &'a str>) {
        let now = Instant::now();
        for key_ref in refs.filter(|r| !r.is_empty()) {
            inner.held.entry(key_ref.to_owned()).or_insert(Held { since: now, seen_waiting: false }).seen_waiting = true;
        }
    }

    /// 지금 이 기기를 기다리는 Welcome 들이 쓴 로비 key package 의 ref(`replenish` 가 지우기 전에 묻는다). 로비 Welcome 목록이 없는
    /// 옛 릴레이(404)는 「모름」 — 빈 집합을 돌려주고, 그때는 [`CONSUMED_HOLD`] 만이 비밀을 지킨다. 그 밖의 오류는 그대로 올린다:
    /// 무엇이 기다리는지 모르는 채로 비밀을 지우지 않는다(이번 보충은 실패하고 다음 틱이 다시 한다).
    fn waiting_refs(inner: &mut Inner, identity: &str) -> Result<HashSet<String>, RoomError> {
        let list = match inner.client.lobby_welcomes(identity) {
            Ok(list) => list,
            Err(api::RelayError::Api { status: 404, .. }) | Err(api::RelayError::Status { status: 404 }) => Vec::new(),
            Err(err) => return Err(relay_err(err)),
        };
        Self::note_waiting(inner, list.iter().map(|w| w.key_package_ref.as_str()));
        Ok(list.into_iter().map(|w| w.key_package_ref).filter(|r| !r.is_empty()).collect())
    }

    fn committed(answer: api::Answer<api::PolicyCommitted>) -> Result<MlsPolicyCommit, RoomError> {
        Ok(match answer {
            api::Answer::Ok(c) => MlsPolicyCommit::Committed { device_id: c.device_id, approved_by: c.approved_by, revision: c.revision, roles: c.roles },
            api::Answer::Refused(r) => MlsPolicyCommit::Refused { refusal: refusal(r) },
        })
    }

    fn snapshot(identity: &str, inner: &Inner) -> Result<MlsLobbySlot, RoomError> {
        let state = inner.device.export_state(identity).map_err(|e| mls_err(rejected(e)))?;
        Ok(MlsLobbySlot { state, published: inner.published.clone() })
    }

    fn persist(&self, inner: &mut Inner) -> Result<(), RoomError> {
        let slot = Self::snapshot(&self.identity, inner)?;
        inner.observer.persist(slot)
    }
}
