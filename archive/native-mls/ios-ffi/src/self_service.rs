//! #366 3g: 기기 셀프서비스(#574) 판정을 uniffi 로 노출한다 — 구현은 host-core `self_service`(공용 벡터
//! `tests/fixtures/self-service-vectors.json` 으로 고정). 와이어·서명은 지금처럼 [`crate::MlsLobby`] 가 한다.
//!
//! - 입력은 [`MlsLobby::me`](crate::MlsLobby)·`list_candidates` 가 돌려준 레코드 그대로(`MlsMe`·`MlsCandidate`).
//! - 「내 기기」 행([`MlsRolesView`])은 **체인 순서**다. 이 기기를 먼저 보이는 것은 호스트 화면의 정렬이다.
//! - iOS Swift 코어는 #271 동결이라 이 함수를 쓰지 않는다(같은 규칙을 Swift 로 갖고 있다). Android `core/SelfService` 가 쓴다.
use native_mls_host::api::{CandidateView, MeDevice, MeInfo};
use native_mls_host::self_service as core;

use crate::{MlsCandidate, MlsMe, MlsMeDevice};

fn device_of(d: &MlsMeDevice) -> MeDevice {
    MeDevice {
        device_id: d.device_id.clone(),
        actor: d.actor.clone(),
        fingerprint: d.fingerprint.clone(),
        status: d.status.clone(),
        acceptance: d.acceptance.clone(),
        roles: d.roles.clone(),
    }
}

fn me_of(me: &Option<MlsMe>) -> Option<MeInfo> {
    me.as_ref().map(|m| MeInfo {
        subject: m.subject.clone(),
        policy_revision: m.policy_revision,
        devices: m.devices.iter().map(device_of).collect(),
    })
}

fn candidate_of(c: &MlsCandidate) -> CandidateView {
    CandidateView {
        device_id: c.device_id.clone(),
        actor: c.actor.clone(),
        subject: c.subject.clone(),
        signing_key: c.signing_key.clone(),
        fingerprint: c.fingerprint.clone(),
        created_at: c.created_at,
        expires_at: c.expires_at,
    }
}

/// 셀프서비스 상수 — 호스트는 자기 상수를 이 값과 같게 둔다(Android `SelfServiceVectorsTest` 가 고정).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsSelfServiceConstants {
    pub role_registrar: String,
    pub status_active: String,
    /// 형제 기기 초대 대기열 수명(마지막 진행부터), ms(#616).
    pub sibling_invite_ttl_ms: u64,
    /// 형제 기기 로비 키 잔량 0 일 때 다시 묻기까지, ms.
    pub sibling_lobby_recheck_ms: u64,
    /// 후보 재게시 여유(만료 이만큼 전), ms.
    pub candidate_repost_margin_ms: u64,
    /// 후보 우편함 행 수명(릴레이 `candidateTTL`), 초.
    pub candidate_ttl_seconds: u64,
}

#[uniffi::export]
pub fn self_service_constants() -> MlsSelfServiceConstants {
    MlsSelfServiceConstants {
        role_registrar: core::ROLE_REGISTRAR.to_owned(),
        status_active: core::STATUS_ACTIVE.to_owned(),
        sibling_invite_ttl_ms: core::SIBLING_INVITE_TTL_MS,
        sibling_lobby_recheck_ms: core::SIBLING_LOBBY_RECHECK_MS,
        candidate_repost_margin_ms: core::CANDIDATE_REPOST_MARGIN_MS,
        candidate_ttl_seconds: core::CANDIDATE_TTL_SECONDS,
    }
}

#[uniffi::export]
pub fn self_service_is_registrar(device: MlsMeDevice) -> bool {
    core::is_registrar(&device_of(&device))
}

#[uniffi::export]
pub fn self_service_is_active(device: MlsMeDevice) -> bool {
    core::is_active(&device_of(&device))
}

/// 이 actor 에 활성 registrar 가 있나(devicepolicy.HasRegistrar).
#[uniffi::export]
pub fn self_service_actor_has_registrar(me: Option<MlsMe>, actor: String) -> bool {
    core::actor_has_registrar(me_of(&me).as_ref(), &actor)
}

/// 이 기기가 같은 actor 의 새 기기를 승인(E2)하거나 역할(E5)에 서명할 수 있나.
#[uniffi::export]
pub fn self_service_can_approve(me: Option<MlsMe>, device: String) -> bool {
    core::can_approve(me_of(&me).as_ref(), &device)
}

/// 로비 Welcome 을 보낸 기기(`from`)가 내 형제 기기인가.
#[uniffi::export]
pub fn self_service_is_sibling(from: Option<String>, me: Option<MlsMe>, actor: Option<String>, device: String) -> bool {
    core::is_sibling(from.as_deref(), me_of(&me).as_ref(), actor.as_deref(), &device)
}

/// 우편함에서 내 actor 의 모양이 온전한 후보만(순서 유지).
#[uniffi::export]
pub fn self_service_candidates_for(list: Vec<MlsCandidate>, actor: String) -> Vec<MlsCandidate> {
    list.into_iter().filter(|c| core::is_candidate_for(&candidate_of(c), &actor)).collect()
}

/// registrar 를 넣거나 뺀 **완전한 정렬 목록**(서버 CanonicalRoles).
#[uniffi::export]
pub fn self_service_next_roles(roles: Vec<String>, grant: bool) -> Vec<String> {
    core::next_roles(&roles, grant)
}

/// 「내 기기」 한 줄의 역할 변경 가능 여부.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsRolesRow {
    pub device_id: String,
    pub registrar: bool,
    pub is_self: bool,
    pub grant: bool,
    pub release: bool,
    pub last_registrar: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsRolesView {
    pub can_sign: bool,
    pub actor: Option<String>,
    /// 체인 순서.
    pub devices: Vec<MlsRolesRow>,
}

#[uniffi::export]
pub fn self_service_roles_actions(me: Option<MlsMe>, device: String) -> MlsRolesView {
    let v = core::roles_actions(me_of(&me).as_ref(), &device);
    MlsRolesView {
        can_sign: v.can_sign,
        actor: v.actor,
        devices: v
            .devices
            .into_iter()
            .map(|d| MlsRolesRow {
                device_id: d.device_id,
                registrar: d.registrar,
                is_self: d.is_self,
                grant: d.grant,
                release: d.release,
                last_registrar: d.last_registrar,
            })
            .collect(),
    }
}

/// 형제 초대 후보 방의 로컬 상태.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsInviteRoom {
    pub room: String,
    pub joined: bool,
    pub halted: bool,
    /// 내 초대 commit 이 아직 echo 전.
    pub pending: bool,
    /// 그룹 명단(모르면 없음).
    pub roster: Option<Vec<String>>,
}

/// 새 형제 기기를 초대할 방(입력 순서 유지).
#[uniffi::export]
pub fn self_service_sibling_invite_rooms(rooms: Vec<MlsInviteRoom>, target: Option<String>) -> Vec<String> {
    let rooms: Vec<core::InviteRoom> = rooms
        .into_iter()
        .map(|r| core::InviteRoom { room: r.room, joined: r.joined, halted: r.halted, pending: r.pending, roster: r.roster })
        .collect();
    core::sibling_invite_rooms(&rooms, target.as_deref())
}

/// 등록 화면 모드.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MlsEnrollMode {
    Operator,
    Sibling,
    IdTaken,
}

/// `POST /v2/devices/candidates` 응답(상태코드 + 봉투의 `error`, 없으면 빈값) → 등록 화면 모드.
#[uniffi::export]
pub fn self_service_enroll_mode(status: u16, code: String) -> MlsEnrollMode {
    match core::enroll_mode_from(status, &code) {
        core::EnrollMode::Operator => MlsEnrollMode::Operator,
        core::EnrollMode::Sibling => MlsEnrollMode::Sibling,
        core::EnrollMode::IdTaken => MlsEnrollMode::IdTaken,
    }
}
