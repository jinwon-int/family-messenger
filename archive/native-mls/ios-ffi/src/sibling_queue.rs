//! #366 3h-a: 형제 초대 대기열과 빠진 방 재탐색(#616) 규칙을 uniffi 로 노출한다 — 구현은 host-core `sibling_queue`(공용 벡터
//! `tests/fixtures/sibling-queue-vectors.json` 으로 고정). 로비 잔량 조회·초대·저장은 호스트가 한다.
//!
//! - Android `core/SelfService`(대기열)·`SiblingRescan` 이 쓴다. 방마다 초대를 부르는 반복(`siblingInviteTurn`)은 호스트에 남고,
//!   끝 계산만 [`sibling_queue_next_entry`] 를 부른다.
//! - 텍스트 저장 형식(`sibling_queue_decode`·`sibling_rescan_decode_state` …)은 Android SharedPreferences 형식이다. 웹은 JSON 을 쓴다.
//! - iOS Swift 코어는 #271 동결이라 이 함수를 쓰지 않는다.
use native_mls_host::self_service::InviteRoom;
use native_mls_host::sibling_queue as core;

use crate::self_service::me_of;
use crate::MlsMe;

/// 대기열 항목(시각은 ms). `progress` = 마지막 초대 성공 시각, `recheck_at` = 로비가 비어 이때까지 묻지 않음, `origin` = 재탐색이 넣은 항목이면 `rescan`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsSiblingInvite {
    pub target: String,
    pub rooms: Vec<String>,
    pub since: i64,
    pub progress: Option<i64>,
    pub recheck_at: Option<i64>,
    pub origin: Option<String>,
}

fn to_core(e: &MlsSiblingInvite) -> core::SiblingInvite {
    core::SiblingInvite {
        target: e.target.clone(),
        rooms: e.rooms.clone(),
        since: e.since,
        progress: e.progress,
        recheck_at: e.recheck_at,
        origin: e.origin.clone(),
    }
}

fn from_core(e: core::SiblingInvite) -> MlsSiblingInvite {
    MlsSiblingInvite { target: e.target, rooms: e.rooms, since: e.since, progress: e.progress, recheck_at: e.recheck_at, origin: e.origin }
}

fn queue_of(q: &[MlsSiblingInvite]) -> Vec<core::SiblingInvite> {
    q.iter().map(to_core).collect()
}

fn queue_from(q: Vec<core::SiblingInvite>) -> Vec<MlsSiblingInvite> {
    q.into_iter().map(from_core).collect()
}

/// 재탐색 상수 — 호스트는 자기 상수를 이 값과 같게 둔다(Android `SiblingQueueVectorsTest` 가 고정).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsSiblingRescanConstants {
    /// 마지막 재탐색 뒤 최소 간격(D3), ms.
    pub interval_ms: i64,
    /// 내가 리더가 아닌 방을 미루는 시간, ms.
    pub deferral_ms: i64,
    /// 재탐색이 넣은 대기열 항목의 출처 표시.
    pub origin: String,
}

#[uniffi::export]
pub fn sibling_rescan_constants() -> MlsSiblingRescanConstants {
    MlsSiblingRescanConstants {
        interval_ms: core::RESCAN_INTERVAL_MS,
        deferral_ms: core::RESCAN_DEFERRAL_MS,
        origin: core::RESCAN_ORIGIN.to_owned(),
    }
}

/// 텍스트 저장값 → 대기열(깨진 줄은 버린다).
#[uniffi::export]
pub fn sibling_queue_decode(text: Option<String>) -> Vec<MlsSiblingInvite> {
    queue_from(core::decode_sibling_queue(text.as_deref()))
}

#[uniffi::export]
pub fn sibling_queue_encode(queue: Vec<MlsSiblingInvite>) -> String {
    core::encode_sibling_queue(&queue_of(&queue))
}

/// (target, rooms) 를 넣는다 — 같은 target 이면 방을 합치고 시각·출처는 유지.
#[uniffi::export]
pub fn sibling_queue_enqueue(queue: Vec<MlsSiblingInvite>, target: String, rooms: Vec<String>, now: i64, origin: Option<String>) -> Vec<MlsSiblingInvite> {
    queue_from(core::enqueue_sibling_invites(&queue_of(&queue), &target, &rooms, now, origin.as_deref()))
}

/// 처리할 것(`live`)과 포기할 것(`expired`, 마지막 진행부터 TTL 지남).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsSiblingSplit {
    pub live: Vec<MlsSiblingInvite>,
    pub expired: Vec<MlsSiblingInvite>,
}

#[uniffi::export]
pub fn sibling_queue_split(queue: Vec<MlsSiblingInvite>, now: i64, ttl: i64) -> MlsSiblingSplit {
    let (live, expired) = core::split_sibling_queue(&queue_of(&queue), now, ttl);
    MlsSiblingSplit { live: queue_from(live), expired: queue_from(expired) }
}

/// 이번 차례에 초대할 방 수(형제 기기 로비 잔량, 모르면 `Int.MAX_VALUE`).
#[uniffi::export]
pub fn sibling_invite_budget(live: Option<i32>) -> i32 {
    core::sibling_invite_budget(live)
}

/// 한 항목의 차례 끝 → 다음 항목(남은 방이 없으면 없음). `starved` 에는 `starved && !progressed` 를 넘긴다.
#[uniffi::export]
pub fn sibling_queue_next_entry(entry: MlsSiblingInvite, remaining: Vec<String>, now: i64, progressed: bool, starved: bool) -> Option<MlsSiblingInvite> {
    core::next_sibling_entry(&to_core(&entry), &remaining, now, progressed, starved).map(from_core)
}

/// 재탐색이 보는 방(초대 판정 입력 + 이번 틱 동기화 여부).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsRescanRoom {
    pub room: String,
    pub joined: bool,
    pub halted: bool,
    pub pending: bool,
    pub roster: Option<Vec<String>>,
    pub synced: bool,
}

/// 미뤄 둔 방 하나: `key` = `target|room`, `seen` = 처음 빠진 것을 본 시각(ms).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsRescanPending {
    pub key: String,
    pub seen: i64,
}

/// 재탐색 상태(`pending` 은 넣은 순서).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsRescanState {
    pub last: Option<i64>,
    pub pending: Vec<MlsRescanPending>,
}

/// 형제 기기 하나의 `excluded_rooms`(없으면 옛 릴레이 — 그 기기는 건너뛴다).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsRescanExcluded {
    pub target: String,
    pub rooms: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsRescanEnqueue {
    pub target: String,
    pub rooms: Vec<String>,
}

/// `ready == false` = 이번 틱에 동기화 안 된 참여 방이 있어 아무것도 안 했다(상태 그대로).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsRescanTurn {
    pub ready: bool,
    pub enqueue: Vec<MlsRescanEnqueue>,
    pub state: MlsRescanState,
}

fn state_of(s: &MlsRescanState) -> core::RescanState {
    core::RescanState {
        last: s.last,
        pending: s.pending.iter().map(|p| core::RescanPending { key: p.key.clone(), seen: p.seen }).collect(),
    }
}

fn state_from(s: core::RescanState) -> MlsRescanState {
    MlsRescanState { last: s.last, pending: s.pending.into_iter().map(|p| MlsRescanPending { key: p.key, seen: p.seen }).collect() }
}

#[uniffi::export]
pub fn sibling_rescan_decode_state(text: Option<String>) -> MlsRescanState {
    state_from(core::decode_rescan_state(text.as_deref()))
}

#[uniffi::export]
pub fn sibling_rescan_encode_state(state: MlsRescanState) -> String {
    core::encode_rescan_state(&state_of(&state))
}

/// 내 actor 의 다른 활성 기기(정렬).
#[uniffi::export]
pub fn sibling_rescan_siblings(me: Option<MlsMe>, device: String) -> Vec<String> {
    core::rescan_siblings(me_of(&me).as_ref(), &device)
}

/// 지금 재탐색할 차례인가.
#[uniffi::export]
pub fn sibling_rescan_due(state: MlsRescanState, now: i64) -> bool {
    core::rescan_due(&state_of(&state), now)
}

/// 재탐색 한 번(순수).
#[uniffi::export]
pub fn sibling_rescan_turn(
    rooms: Vec<MlsRescanRoom>,
    device: String,
    siblings: Vec<String>,
    excluded: Vec<MlsRescanExcluded>,
    state: MlsRescanState,
    now: i64,
) -> MlsRescanTurn {
    let rooms: Vec<core::RescanRoom> = rooms
        .into_iter()
        .map(|r| core::RescanRoom {
            room: InviteRoom { room: r.room, joined: r.joined, halted: r.halted, pending: r.pending, roster: r.roster },
            synced: r.synced,
        })
        .collect();
    let lookup = |t: &str| excluded.iter().find(|e| e.target == t).and_then(|e| e.rooms.as_deref());
    let turn = core::rescan_turn(&rooms, &device, &siblings, lookup, &state_of(&state), now);
    MlsRescanTurn {
        ready: turn.ready,
        enqueue: turn.enqueue.into_iter().map(|(target, rooms)| MlsRescanEnqueue { target, rooms }).collect(),
        state: state_from(turn.state),
    }
}

// ---- #875 (#366 3h-b 1차): 명단에는 있는데 참여하지 못한 형제 기기 복구(경우 A) ----

/// 복구 상수 — Android `SiblingRepair` 가 같은 값을 둔다(`SiblingQueueVectorsTest` 가 고정).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsSiblingRepairConstants {
    /// Welcome 이 이만큼 소비되지 않은 채 남아야 멈춤으로 본다, ms.
    pub min_age_ms: i64,
    /// 같은 (형제 기기, 방) 재복구까지 최소 간격, ms.
    pub interval_ms: i64,
    /// 복구가 넣은 대기열 항목의 출처 표시.
    pub origin: String,
}

#[uniffi::export]
pub fn sibling_repair_constants() -> MlsSiblingRepairConstants {
    MlsSiblingRepairConstants {
        min_age_ms: core::REPAIR_MIN_AGE_MS,
        interval_ms: core::REPAIR_INTERVAL_MS,
        origin: core::REPAIR_ORIGIN.to_owned(),
    }
}

/// 형제 기기를 대상으로 남은 Welcome 한 건(`created_at_ms` = 릴레이 `created_at` 초 × 1000).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsSiblingWelcome {
    pub room: String,
    pub created_at_ms: i64,
}

/// 복구 기록 한 건: `key` = `target|room`, `at` = 마지막으로 내보낸 시각(ms).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsRepairMark {
    pub key: String,
    pub at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsRepairState {
    pub marks: Vec<MlsRepairMark>,
}

fn repair_of(s: &MlsRepairState) -> core::RepairState {
    core::RepairState { marks: s.marks.iter().map(|m| core::RepairMark { key: m.key.clone(), at: m.at }).collect() }
}

fn repair_from(s: core::RepairState) -> MlsRepairState {
    MlsRepairState { marks: s.marks.into_iter().map(|m| MlsRepairMark { key: m.key, at: m.at }).collect() }
}

/// 이 기기가 복구를 해도 되나(체인의 내 기록이 활성 · registrar).
#[uniffi::export]
pub fn sibling_repair_allowed(me: Option<MlsMe>, device: String) -> bool {
    core::may_repair(me_of(&me).as_ref(), &device)
}

/// 형제 기기 `target` 을 내보내고 다시 초대할 방(경우 A, 방마다 24시간 한 번).
#[uniffi::export]
pub fn sibling_repair_stuck_rooms(
    rooms: Vec<crate::MlsInviteRoom>,
    target: String,
    welcomes: Vec<MlsSiblingWelcome>,
    state: MlsRepairState,
    now: i64,
) -> Vec<String> {
    let rooms: Vec<InviteRoom> = rooms
        .into_iter()
        .map(|r| InviteRoom { room: r.room, joined: r.joined, halted: r.halted, pending: r.pending, roster: r.roster })
        .collect();
    let welcomes: Vec<core::SiblingWelcome> =
        welcomes.into_iter().map(|w| core::SiblingWelcome { room: w.room, created_at_ms: w.created_at_ms }).collect();
    core::stuck_sibling_rooms(&rooms, &target, &welcomes, &repair_of(&state), now)
}

/// (target, room) 을 `now` 에 복구했다고 적는다(24시간 지난 기록은 걷어 낸다).
#[uniffi::export]
pub fn sibling_repair_mark(state: MlsRepairState, target: String, room: String, now: i64) -> MlsRepairState {
    repair_from(core::mark_repaired(&repair_of(&state), &target, &room, now))
}

#[uniffi::export]
pub fn sibling_repair_decode_state(text: Option<String>) -> MlsRepairState {
    repair_from(core::decode_repair_state(text.as_deref()))
}

#[uniffi::export]
pub fn sibling_repair_encode_state(state: MlsRepairState) -> String {
    core::encode_repair_state(&repair_of(&state))
}
