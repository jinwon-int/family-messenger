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
//! 장부(`published`) 앞쪽 `published.len() - live` 개가 소비·만료된 것이다 — 그만큼 로컬 비밀을 `delete_key_package` 로 지워
//! 파사드 상한(8)을 비우고, 부족분을 새로 만들어 게시한다. 비밀은 **게시 전에** 영속한다(persist-before-bytes-leave); 게시에
//! 실패한 새 key package 는 비밀을 바로 지운다(서버에 없는 키는 로컬 상한만 차지한다).
use std::sync::{Arc, Mutex, MutexGuard};

use family_mls_browser_experiment::Device;
use native_mls_host::api::{self, Access, Client};

use crate::room::{mls_err, relay_err, ForeignTransport, HttpTransport, RoomError};
use crate::{dispatch_guarded, rejected, MlsError};

/// 로비 슬롯의 저장 형식(호스트가 통째로 봉인·영속; `import` 로 되돌린다).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LobbySlot {
    /// 파사드 `export_state`: 서명키 시드 + 로비 key package 비밀.
    pub state: Vec<u8>,
    /// 릴레이가 받은 key package 바이트(게시 순 = 릴레이 소비 순).
    pub published: Vec<Vec<u8>>,
}

/// `GET /v2/lobby/status` — 서버의 미소비 수와 정책 상한.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LobbyStatus {
    pub live: u32,
    pub max: u32,
    pub ttl_seconds: i64,
}

/// `replenish` 한 번의 결과(화면·테스트).
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct LobbyReport {
    /// 보충 뒤 서버의 미소비 수.
    pub live: u32,
    pub max: u32,
    pub minted: u32,
    /// 소비·만료된 것으로 판단해 로컬 비밀을 지운 수.
    pub pruned: u32,
}

/// 이 기기가 아직 읽지 않은 Welcome 을 들고 있는 방(`GET /v2/lobby/welcomes`). `MlsRoom::adopt(…, seq - 1, …)` 로 받아들인다.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct PendingWelcome {
    pub room: String,
    pub seq: i64,
    pub epoch: i64,
    pub created_at: i64,
}

/// 이 기기가 참여하는 방 하나(`GET /v2/rooms`): 공개 필드만.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct RoomListing {
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
    fn persist(&self, slot: LobbySlot) -> Result<(), RoomError>;
}

/// 기기 하나 = 로비 파사드 `Device` 하나 + 게시 장부. 메서드는 `&self`, 내부 Mutex 로 직렬화.
#[derive(uniffi::Object)]
pub struct MlsLobby {
    identity: String,
    inner: Mutex<Inner>,
}

struct Inner {
    device: Device,
    published: Vec<Vec<u8>>,
    client: Client,
    observer: Arc<dyn LobbyObserver>,
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
        identity: String, slot: LobbySlot, base_url: String, transport: Arc<dyn HttpTransport>, observer: Arc<dyn LobbyObserver>,
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
        inner.client.set_access(match token { Some(t) => Access::Static(t), None => Access::None });
        Ok(())
    }

    /// 로비 상태 바이트 — `MlsRoom::adopt` 의 `state`(방을 만들 때 `after` = 0, Welcome 을 받아들일 때 `seq - 1`).
    pub fn seed_state(&self) -> Result<Vec<u8>, RoomError> {
        let inner = self.lock()?;
        inner.device.export_state(&self.identity).map_err(|e| mls_err(rejected(e)))
    }

    /// 지금 슬롯의 스냅샷(디버그·백업 — 영속의 정본은 `persist` 콜백).
    pub fn slot(&self) -> Result<LobbySlot, RoomError> {
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
    pub fn status(&self) -> Result<LobbyStatus, RoomError> {
        let inner = self.lock()?;
        let status = inner.client.lobby_status(&self.identity).map_err(relay_err)?;
        Ok(LobbyStatus { live: status.live as u32, max: status.max as u32, ttl_seconds: status.ttl_seconds })
    }

    /// 서버의 미소비 수가 `min(target, 서버 max)` 보다 적으면 그만큼 만들어 게시한다. 먼저 장부 앞쪽(소비·만료분)의 로컬 비밀을
    /// 지운다. 파사드 상한(8)에 닿으면 거기서 멈춘다(오류 아님). 앱은 시작·포그라운드·방 참여 뒤에 부른다(iOS 와 같은 시점).
    pub fn replenish(&self, target: u32) -> Result<LobbyReport, RoomError> {
        let mut inner = self.lock()?;
        let status = inner.client.lobby_status(&self.identity).map_err(relay_err)?;
        let goal = (target as u64).min(status.max) as usize;
        let live = status.live as usize;

        // ① 소비·만료분의 로컬 비밀 — 이미 없는(모르는) 것은 거부되지만 장부에서는 뺀다.
        let consumed = inner.published.len().saturating_sub(live);
        let mut pruned = 0u32;
        let Inner { device, published, .. } = &mut *inner;
        for bytes in published.drain(..consumed) {
            if dispatch_guarded(device, &self.identity, "delete_key_package", &bytes).is_ok() {
                pruned += 1;
            }
        }
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
            return Ok(LobbyReport { live: status.live as u32, max: status.max as u32, minted: 0, pruned });
        }
        // ④ 게시. 실패하면 서버가 받지 않은 키의 비밀은 버린다 — 다음 보충이 다시 만든다.
        let refs: Vec<(String, Vec<u8>)> = fresh.iter().map(|kp| (api::ref_hex(kp), kp.clone())).collect();
        let borrowed: Vec<(&str, Vec<u8>)> = refs.iter().map(|(r, kp)| (r.as_str(), kp.clone())).collect();
        match inner.client.post_lobby_key_packages(&self.identity, &borrowed) {
            Ok(stored) => {
                inner.published.extend(fresh.iter().cloned());
                self.persist(&mut inner)?;
                Ok(LobbyReport { live: stored.live as u32, max: status.max as u32, minted: fresh.len() as u32, pruned })
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
    pub fn welcomes(&self) -> Result<Vec<PendingWelcome>, RoomError> {
        let inner = self.lock()?;
        let list = inner.client.lobby_welcomes(&self.identity).map_err(relay_err)?;
        Ok(list
            .into_iter()
            .map(|w| PendingWelcome { room: w.room, seq: w.seq, epoch: w.epoch, created_at: w.created_at })
            .collect())
    }

    /// `DELETE /v2/lobby/keypackages?device=`(#389, 「이 기기 지우기」 직전): 미소비 로비 키를 거두고 그 비밀도 지운다. 거둔 개수.
    pub fn withdraw(&self) -> Result<u64, RoomError> {
        let mut inner = self.lock()?;
        let deleted = inner.client.delete_lobby_key_packages(&self.identity).map_err(relay_err)?;
        let Inner { device, published, .. } = &mut *inner;
        for bytes in published.drain(..) {
            let _ = dispatch_guarded(device, &self.identity, "delete_key_package", &bytes);
        }
        self.persist(&mut inner)?;
        Ok(deleted)
    }

    /// `GET /v2/rooms?device=`: 이 기기가 참여하는 방 목록(공개 필드만).
    pub fn rooms(&self) -> Result<Vec<RoomListing>, RoomError> {
        let inner = self.lock()?;
        let list = inner.client.list_rooms(&self.identity).map_err(relay_err)?;
        Ok(list
            .into_iter()
            .map(|r| RoomListing {
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
}

impl MlsLobby {
    fn assemble(
        identity: String, device: Device, published: Vec<Vec<u8>>, base_url: String, transport: Arc<dyn HttpTransport>,
        observer: Arc<dyn LobbyObserver>,
    ) -> Arc<Self> {
        let client = Client::with_transport(&base_url, Access::None, Box::new(ForeignTransport(transport)));
        Arc::new(Self { identity, inner: Mutex::new(Inner { device, published, client, observer }) })
    }

    fn lock(&self) -> Result<MutexGuard<'_, Inner>, RoomError> {
        self.inner.lock().map_err(|_| RoomError::Host { reason: "lobby lock poisoned".into() })
    }

    fn snapshot(identity: &str, inner: &Inner) -> Result<LobbySlot, RoomError> {
        let state = inner.device.export_state(identity).map_err(|e| mls_err(rejected(e)))?;
        Ok(LobbySlot { state, published: inner.published.clone() })
    }

    fn persist(&self, inner: &mut Inner) -> Result<(), RoomError> {
        let slot = Self::snapshot(&self.identity, inner)?;
        inner.observer.persist(slot)
    }
}
