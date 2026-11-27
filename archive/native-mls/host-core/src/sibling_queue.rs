//! Sibling-invite queue and missing-room rescan (#616, #366 slice 3h-a): the pure rules,
//! moved out of Android `core/SelfService.kt` (`SelfService` queue helpers and `SiblingRescan`)
//! — the same rules the web keeps in `hande/self-service.js` and iOS in its frozen Swift copy
//! (#271). Hosts keep the network (lobby status, invites), storage and the per-room loop that
//! calls them; this module only decides.
//!
//! - Queue: a device that approved a new sibling remembers which rooms to invite it into and
//!   retries every tick. Lifetime is measured from the **last progress** ([`SIBLING_INVITE_TTL_MS`]).
//!   Each invite consumes one of the sibling's lobby key packages, so a turn spends at most the
//!   sibling's live count ([`sibling_invite_budget`]).
//! - Rescan (owner decisions D1–D3): at least every [`RESCAN_INTERVAL_MS`], recompute the rooms my
//!   other active devices are missing and feed them to the same queue. Rooms the relay reports as
//!   removed by commit (`excluded_rooms`) are skipped; a sibling without that field (old relay) is
//!   skipped entirely (fail-closed). Per room only the lowest device ID of mine invites at once;
//!   the others wait [`RESCAN_DEFERRAL_MS`].
//! - Text storage format: the line format Android keeps in SharedPreferences
//!   (`sibling_invites`, `sibling_rescan`). The web stores JSON and does not use it.
//!
//! Fixed by `archive/native-mls/tests/fixtures/sibling-queue-vectors.json`, which ios-ffi,
//! Android and (for the rules, not the text format) the web run as well.

use crate::api::MeInfo;
use crate::self_service::{is_active, sibling_invite_rooms, InviteRoom, SIBLING_LOBBY_RECHECK_MS};

/// D3: minimum interval between rescans.
pub const RESCAN_INTERVAL_MS: i64 = 6 * 60 * 60_000;
/// A room where I am not the lowest device ID of mine is taken only after it stays missing this long.
pub const RESCAN_DEFERRAL_MS: i64 = 30 * 60_000;
/// `origin` of queue entries the rescan adds (their give-up/failure is not announced).
pub const RESCAN_ORIGIN: &str = "rescan";

/// One queue entry. `progress` = last time an invite succeeded (the TTL runs from it, else from
/// `since`); `recheck_at` = the sibling's lobby was empty, do not ask again before this;
/// `origin` = [`RESCAN_ORIGIN`] for entries the rescan created.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SiblingInvite {
    pub target: String,
    pub rooms: Vec<String>,
    pub since: i64,
    pub progress: Option<i64>,
    pub recheck_at: Option<i64>,
    pub origin: Option<String>,
}

/// `^[A-Za-z0-9_-]{1,64}$` — device, room and origin identifiers.
pub fn is_ident(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Kotlin `CharSequence.lines()`: split on CRLF, LF or CR.
fn kotlin_lines(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let bytes = text.as_bytes();
    let mut start = 0;
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\r' => {
                out.push(&text[start..i]);
                i += if bytes.get(i + 1) == Some(&b'\n') { 2 } else { 1 };
                start = i;
            }
            b'\n' => {
                out.push(&text[start..i]);
                i += 1;
                start = i;
            }
            _ => i += 1,
        }
    }
    out.push(&text[start..]);
    out
}

fn parse_i64(s: &str) -> Option<i64> {
    s.parse::<i64>().ok()
}

/// Text storage → queue. One entry per line, `target|sinceMs|room1,room2`, optionally followed by
/// `|progressMs|recheckAtMs|origin` (empty field = absent). Malformed lines are dropped; room IDs
/// that are not identifiers are dropped from their line.
pub fn decode_sibling_queue(text: Option<&str>) -> Vec<SiblingInvite> {
    let Some(text) = text else { return Vec::new() };
    if text.chars().all(char::is_whitespace) {
        return Vec::new();
    }
    let mut out = Vec::new();
    for line in kotlin_lines(text) {
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() != 3 && parts.len() != 6 {
            continue;
        }
        if !is_ident(parts[0]) {
            continue;
        }
        let Some(since) = parse_i64(parts[1]) else { continue };
        let rooms: Vec<String> = parts[2].split(',').filter(|r| is_ident(r)).map(str::to_owned).collect();
        let mut e = SiblingInvite { target: parts[0].to_owned(), rooms, since, progress: None, recheck_at: None, origin: None };
        if parts.len() == 6 {
            let opt = |s: &str| -> Result<Option<i64>, ()> {
                if s.is_empty() {
                    Ok(None)
                } else {
                    parse_i64(s).map(Some).ok_or(())
                }
            };
            let (Ok(progress), Ok(recheck_at)) = (opt(parts[3]), opt(parts[4])) else { continue };
            let origin = (!parts[5].is_empty()).then(|| parts[5].to_owned());
            if origin.as_deref().is_some_and(|o| !is_ident(o)) {
                continue;
            }
            e.progress = progress;
            e.recheck_at = recheck_at;
            e.origin = origin;
        }
        out.push(e);
    }
    out
}

/// Queue → text storage (the 3-field form when an entry carries no progress information).
pub fn encode_sibling_queue(queue: &[SiblingInvite]) -> String {
    queue
        .iter()
        .map(|e| {
            let base = format!("{}|{}|{}", e.target, e.since, e.rooms.join(","));
            if e.progress.is_none() && e.recheck_at.is_none() && e.origin.is_none() {
                base
            } else {
                let o = |v: Option<i64>| v.map(|n| n.to_string()).unwrap_or_default();
                format!("{base}|{}|{}|{}", o(e.progress), o(e.recheck_at), e.origin.as_deref().unwrap_or(""))
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn distinct(items: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for s in items {
        if !out.contains(&s) {
            out.push(s);
        }
    }
    out
}

/// Add (target, rooms): an existing entry of the same target gets the rooms merged (its times
/// and origin are kept); otherwise a new entry starts at `now`. No non-empty room → unchanged.
pub fn enqueue_sibling_invites(
    queue: &[SiblingInvite],
    target: &str,
    rooms: &[String],
    now: i64,
    origin: Option<&str>,
) -> Vec<SiblingInvite> {
    let add = distinct(rooms.iter().filter(|r| !r.is_empty()).cloned());
    if add.is_empty() {
        return queue.to_vec();
    }
    let mut out = queue.to_vec();
    match out.iter_mut().find(|e| e.target == target) {
        Some(e) => e.rooms = distinct(e.rooms.iter().cloned().chain(add)),
        None => out.push(SiblingInvite {
            target: target.to_owned(),
            rooms: add,
            since: now,
            progress: None,
            recheck_at: None,
            origin: origin.map(str::to_owned),
        }),
    }
    out
}

/// (live, expired): expired = more than `ttl` since the last progress (else since `since`).
pub fn split_sibling_queue(queue: &[SiblingInvite], now: i64, ttl: i64) -> (Vec<SiblingInvite>, Vec<SiblingInvite>) {
    queue.iter().cloned().partition(|e| now - e.progress.unwrap_or(e.since) <= ttl)
}

/// Invites to try this turn: the sibling's live lobby key count (`None` = unknown → no limit,
/// [`i32::MAX`]); never negative.
pub fn sibling_invite_budget(live: Option<i32>) -> i32 {
    match live {
        None => i32::MAX,
        Some(n) => n.max(0),
    }
}

/// End of one entry's turn → the next queue entry (`None` when no room remains). A success
/// restarts the TTL (`progress = now`); `starved` (lobby empty and nothing invited — the caller
/// passes `starved && !progressed`) sets `recheck_at`, otherwise it is cleared.
pub fn next_sibling_entry(entry: &SiblingInvite, remaining: &[String], now: i64, progressed: bool, starved: bool) -> Option<SiblingInvite> {
    if remaining.is_empty() {
        return None;
    }
    Some(SiblingInvite {
        rooms: remaining.to_vec(),
        progress: if progressed { Some(now) } else { entry.progress },
        recheck_at: starved.then_some(now + SIBLING_LOBBY_RECHECK_MS as i64),
        ..entry.clone()
    })
}

/// A room as the rescan sees it: the invite view plus `synced` (this tick's poll succeeded).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RescanRoom {
    pub room: InviteRoom,
    pub synced: bool,
}

/// One deferred room: `key` = `target|room`, `seen` = when it was first seen missing (ms).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RescanPending {
    pub key: String,
    pub seen: i64,
}

/// Rescan state: `last` = last run (ms), `pending` in insertion order.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RescanState {
    pub last: Option<i64>,
    pub pending: Vec<RescanPending>,
}

/// `ready == false`: a joined room is not synced this tick — nothing done, state unchanged.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RescanTurn {
    pub ready: bool,
    /// (target, rooms) to add to the queue with origin [`RESCAN_ORIGIN`].
    pub enqueue: Vec<(String, Vec<String>)>,
    pub state: RescanState,
}

/// Text storage → state: first line `last` (empty = never), then `target|room|seenMs` per line
/// (LF only). A broken first line gives the empty state; broken lines are dropped; a repeated
/// key keeps its first position with the later value.
pub fn decode_rescan_state(text: Option<&str>) -> RescanState {
    let Some(text) = text.filter(|t| !t.is_empty()) else { return RescanState::default() };
    let mut lines = text.split('\n');
    let head = lines.next().unwrap_or("");
    let last = if head.is_empty() {
        None
    } else {
        match parse_i64(head) {
            Some(n) => Some(n),
            None => return RescanState::default(),
        }
    };
    let mut pending: Vec<RescanPending> = Vec::new();
    for line in lines {
        let p: Vec<&str> = line.split('|').collect();
        if p.len() != 3 || !is_ident(p[0]) || !is_ident(p[1]) {
            continue;
        }
        let Some(seen) = parse_i64(p[2]) else { continue };
        let key = format!("{}|{}", p[0], p[1]);
        match pending.iter_mut().find(|e| e.key == key) {
            Some(e) => e.seen = seen,
            None => pending.push(RescanPending { key, seen }),
        }
    }
    RescanState { last, pending }
}

pub fn encode_rescan_state(state: &RescanState) -> String {
    std::iter::once(state.last.map(|n| n.to_string()).unwrap_or_default())
        .chain(state.pending.iter().map(|e| format!("{}|{}", e.key, e.seen)))
        .collect::<Vec<_>>()
        .join("\n")
}

/// My actor's other active devices (sorted). Empty when my record is missing, inactive or has no actor.
pub fn rescan_siblings(me: Option<&MeInfo>, device: &str) -> Vec<String> {
    let devices = me.map_or(&[][..], |m| m.devices.as_slice());
    let Some(mine) = devices.iter().find(|d| d.device_id == device) else { return Vec::new() };
    if !is_active(mine) || mine.actor.is_empty() {
        return Vec::new();
    }
    let mut out: Vec<String> = devices
        .iter()
        .filter(|d| d.device_id != device && d.actor == mine.actor && is_active(d))
        .map(|d| d.device_id.clone())
        .collect();
    out.sort();
    out
}

/// Time to rescan: never ran, the interval passed, or a deferred room's wait is over.
pub fn rescan_due(state: &RescanState, now: i64) -> bool {
    let Some(last) = state.last else { return true };
    if now - last >= RESCAN_INTERVAL_MS {
        return true;
    }
    state.pending.iter().any(|e| now - e.seen >= RESCAN_DEFERRAL_MS)
}

/// One rescan (pure). `excluded(target)` = the rooms the relay reports as removed by commit;
/// `None` (old relay, no lookup) skips that sibling.
pub fn rescan_turn<'a>(
    rooms: &[RescanRoom],
    device: &str,
    siblings: &[String],
    excluded: impl Fn(&str) -> Option<&'a [String]>,
    state: &RescanState,
    now: i64,
) -> RescanTurn {
    if rooms.iter().any(|r| r.room.joined && !r.synced) {
        return RescanTurn { ready: false, enqueue: Vec::new(), state: state.clone() };
    }
    let views: Vec<InviteRoom> = rooms.iter().map(|r| r.room.clone()).collect();
    let mine: Vec<&str> = std::iter::once(device).chain(siblings.iter().map(String::as_str)).collect();
    let mut pending: Vec<RescanPending> = Vec::new();
    let mut enqueue = Vec::new();
    for target in siblings {
        let Some(out) = excluded(target) else { continue };
        let mut take = Vec::new();
        for room_id in sibling_invite_rooms(&views, Some(target)) {
            if out.contains(&room_id) {
                continue;
            }
            let Some(view) = views.iter().find(|v| v.room == room_id) else { continue };
            let present = view.roster.iter().flatten().filter(|m| mine.contains(&m.as_str())).map(String::as_str);
            let leader = std::iter::once(device).chain(present).min().unwrap_or(device);
            if leader == device {
                take.push(room_id);
                continue;
            }
            let key = format!("{target}|{room_id}");
            let seen = state.pending.iter().find(|e| e.key == key).map_or(now, |e| e.seen);
            if now - seen >= RESCAN_DEFERRAL_MS {
                take.push(room_id);
            } else if !pending.iter().any(|e| e.key == key) {
                pending.push(RescanPending { key, seen });
            }
        }
        if !take.is_empty() {
            enqueue.push((target.clone(), take));
        }
    }
    RescanTurn { ready: true, enqueue, state: RescanState { last: Some(now), pending } }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::self_service::{SIBLING_INVITE_TTL_MS, SIBLING_LOBBY_RECHECK_MS};
    use serde_json::{json, Value};

    fn fixture() -> Value {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/fixtures/sibling-queue-vectors.json");
        serde_json::from_str(&std::fs::read_to_string(path).expect("sibling-queue-vectors.json")).expect("valid json")
    }

    fn cases<'a>(f: &'a Value, key: &str) -> &'a Vec<Value> {
        let v = f[key].as_array().unwrap_or_else(|| panic!("{key} missing"));
        assert!(!v.is_empty(), "{key} empty");
        v
    }

    fn strings(v: &Value) -> Vec<String> {
        v.as_array().unwrap().iter().map(|s| s.as_str().unwrap().to_owned()).collect()
    }

    fn entry(v: &Value) -> SiblingInvite {
        SiblingInvite {
            target: v["target"].as_str().unwrap().to_owned(),
            rooms: strings(&v["rooms"]),
            since: v["since"].as_i64().unwrap(),
            progress: v["progress"].as_i64(),
            recheck_at: v["recheck_at"].as_i64(),
            origin: v["origin"].as_str().map(str::to_owned),
        }
    }

    fn entry_json(e: &SiblingInvite) -> Value {
        json!({"target": e.target, "rooms": e.rooms, "since": e.since, "progress": e.progress,
            "recheck_at": e.recheck_at, "origin": e.origin})
    }

    fn state(v: &Value) -> RescanState {
        RescanState {
            last: v["last"].as_i64(),
            pending: v["pending"]
                .as_array()
                .unwrap()
                .iter()
                .map(|p| RescanPending { key: p["key"].as_str().unwrap().to_owned(), seen: p["seen"].as_i64().unwrap() })
                .collect(),
        }
    }

    fn state_json(s: &RescanState) -> Value {
        json!({"last": s.last, "pending": s.pending.iter().map(|p| json!({"key": p.key, "seen": p.seen})).collect::<Vec<_>>()})
    }

    #[test]
    fn constants_match_the_vectors() {
        let c = &fixture()["constants"];
        assert_eq!(c["rescan_interval_ms"], RESCAN_INTERVAL_MS);
        assert_eq!(c["rescan_deferral_ms"], RESCAN_DEFERRAL_MS);
        assert_eq!(c["rescan_origin"], RESCAN_ORIGIN);
        assert_eq!(c["sibling_lobby_recheck_ms"], SIBLING_LOBBY_RECHECK_MS);
        assert_eq!(c["sibling_invite_ttl_ms"], SIBLING_INVITE_TTL_MS);
    }

    #[test]
    fn queue_vectors() {
        let f = fixture();
        for c in cases(&f, "enqueue") {
            let q: Vec<SiblingInvite> = c["queue"].as_array().unwrap().iter().map(entry).collect();
            let got = enqueue_sibling_invites(&q, c["target"].as_str().unwrap(), &strings(&c["rooms"]), c["now"].as_i64().unwrap(), c["origin"].as_str());
            assert_eq!(Value::Array(got.iter().map(entry_json).collect()), c["expect"], "{}", c["name"]);
        }
        for c in cases(&f, "split") {
            let q: Vec<SiblingInvite> = c["queue"].as_array().unwrap().iter().map(entry).collect();
            let (live, expired) = split_sibling_queue(&q, c["now"].as_i64().unwrap(), c["ttl"].as_i64().unwrap());
            let t = |v: &[SiblingInvite]| v.iter().map(|e| e.target.clone()).collect::<Vec<_>>();
            assert_eq!(json!({"live": t(&live), "expired": t(&expired)}), c["expect"], "{}", c["name"]);
        }
        for c in cases(&f, "budget") {
            let got = sibling_invite_budget(c["live"].as_i64().map(|n| n as i32));
            let want = c["expect"].as_i64().map_or(i32::MAX, |n| n as i32);
            assert_eq!(got, want, "{}", c["name"]);
        }
        for c in cases(&f, "next_entry") {
            let got = next_sibling_entry(
                &entry(&c["entry"]),
                &strings(&c["remaining"]),
                c["now"].as_i64().unwrap(),
                c["progressed"].as_bool().unwrap(),
                c["starved"].as_bool().unwrap(),
            );
            assert_eq!(got.as_ref().map_or(Value::Null, entry_json), c["expect"], "{}", c["name"]);
        }
        for c in cases(&f, "queue_text_decode") {
            let got = decode_sibling_queue(c["text"].as_str());
            assert_eq!(Value::Array(got.iter().map(entry_json).collect()), c["expect"], "{}", c["name"]);
        }
        for c in cases(&f, "queue_text_encode") {
            let q: Vec<SiblingInvite> = c["queue"].as_array().unwrap().iter().map(entry).collect();
            let text = encode_sibling_queue(&q);
            assert_eq!(text, c["expect"].as_str().unwrap(), "{}", c["name"]);
            assert_eq!(decode_sibling_queue(Some(&text)), q, "round trip {}", c["name"]);
        }
    }

    #[test]
    fn rescan_vectors() {
        let f = fixture();
        for c in cases(&f, "rescan_siblings") {
            let me: Option<MeInfo> = c["me"].as_str().map(|k| serde_json::from_value(f["mes"][k].clone()).expect("me record"));
            assert_eq!(rescan_siblings(me.as_ref(), c["device"].as_str().unwrap()), strings(&c["expect"]), "{}", c["name"]);
        }
        for c in cases(&f, "rescan_due") {
            assert_eq!(rescan_due(&state(&c["state"]), c["now"].as_i64().unwrap()), c["expect"], "{}", c["name"]);
        }
        for c in cases(&f, "rescan_turn") {
            let rooms: Vec<RescanRoom> = c["rooms"]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| RescanRoom {
                    room: InviteRoom {
                        room: r["room"].as_str().unwrap().to_owned(),
                        joined: r["joined"].as_bool().unwrap(),
                        halted: r["halted"].as_bool().unwrap(),
                        pending: r["pending"].as_bool().unwrap(),
                        roster: serde_json::from_value(r["roster"].clone()).unwrap(),
                    },
                    synced: r["synced"].as_bool().unwrap(),
                })
                .collect();
            let excluded: Vec<(String, Option<Vec<String>>)> = c["excluded"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.clone(), v.as_array().map(|_| strings(v))))
                .collect();
            let lookup = |t: &str| excluded.iter().find(|(k, _)| k == t).and_then(|(_, v)| v.as_deref());
            let r = rescan_turn(&rooms, c["device"].as_str().unwrap(), &strings(&c["siblings"]), lookup, &state(&c["state"]), c["now"].as_i64().unwrap());
            let got = json!({"ready": r.ready,
                "enqueue": r.enqueue.iter().map(|(t, rs)| json!({"target": t, "rooms": rs})).collect::<Vec<_>>(),
                "state": state_json(&r.state)});
            assert_eq!(got, c["expect"], "{}", c["name"]);
        }
        for c in cases(&f, "rescan_state_text_decode") {
            assert_eq!(state_json(&decode_rescan_state(c["text"].as_str())), c["expect"], "{}", c["name"]);
        }
        for c in cases(&f, "rescan_state_text_encode") {
            let s = state(&c["state"]);
            let text = encode_rescan_state(&s);
            assert_eq!(text, c["expect"].as_str().unwrap(), "{}", c["name"]);
            assert_eq!(decode_rescan_state(Some(&text)), s, "round trip {}", c["name"]);
        }
    }
}
