//! Device self-service decisions (#574, #366 slice 3g): **who** may do **what** with the
//! subject's chain records. Moved out of the hosts' copies — Android `core/SelfService.kt` and
//! web `hande/self-service.js` (same names, same rules) — so the rule lives in one place.
//! The wire (`/v2/me`, candidates, approvals, roles) and the signatures stay in [`crate::api`]
//! and the facade; nothing here talks to the relay or stores anything.
//!
//! Server contract (server/devices.go · me.go, DEVICES-V4 「셀프서비스 라우트」):
//! a device may sign an approval (E2) or a roles change (E5) when it is active and either a
//! registrar or of an actor with no active registrar (devicepolicy.VerifyApproval/VerifyRoles).
//! The last registrar cannot release itself; approvals only between devices of one actor.
//!
//! Fixed by `archive/native-mls/tests/fixtures/self-service-vectors.json`, which the web and
//! Android tests run as well. iOS keeps its Swift copy (#271 frozen contract).

use crate::api::{CandidateView, MeDevice, MeInfo};

/// The only role the chain knows today.
pub const ROLE_REGISTRAR: &str = "registrar";
/// Chain status of a usable device (the other is `revoked`).
pub const STATUS_ACTIVE: &str = "active";
/// Lifetime of a sibling-invite queue entry, measured from its **last progress** (#616).
pub const SIBLING_INVITE_TTL_MS: u64 = 24 * 60 * 60_000;
/// #616: with the sibling's lobby at zero keys, wait this long before asking again.
pub const SIBLING_LOBBY_RECHECK_MS: u64 = 60_000;
/// Re-post a candidate this long before it expires.
pub const CANDIDATE_REPOST_MARGIN_MS: u64 = 5 * 60_000;
/// Mailbox row lifetime (relay `server/devices.go` `candidateTTL`), seconds.
pub const CANDIDATE_TTL_SECONDS: u64 = 10 * 60;

/// Enrollment screen mode after `POST /v2/devices/candidates`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EnrollMode {
    /// Anything but the two below (403 first_device_out_of_band · subject_mismatch, 404 old
    /// relay or no access auth, 5xx): the operator enrolls this device.
    Operator,
    /// 201: a sibling device approves it.
    Sibling,
    /// 409 `device_exists`: this device ID can never be used again.
    IdTaken,
}

pub fn is_registrar(d: &MeDevice) -> bool {
    d.roles.iter().any(|r| r == ROLE_REGISTRAR)
}

pub fn is_active(d: &MeDevice) -> bool {
    d.status == STATUS_ACTIVE
}

/// This device's chain record (`None` on an old relay or before it is on the chain).
pub fn record_of<'a>(me: Option<&'a MeInfo>, device: &str) -> Option<&'a MeDevice> {
    me?.devices.iter().find(|d| d.device_id == device)
}

/// Does this actor have at least one active registrar (devicepolicy.HasRegistrar)?
pub fn actor_has_registrar(me: Option<&MeInfo>, actor: &str) -> bool {
    me.map_or(false, |m| m.devices.iter().any(|d| d.actor == actor && is_active(d) && is_registrar(d)))
}

/// May this device approve a new device of its actor (E2) or sign a roles change (E5)?
/// Active, and a registrar or of an actor without one (the pre-#574 「any active device」 rule).
pub fn can_approve(me: Option<&MeInfo>, device: &str) -> bool {
    match record_of(me, device) {
        Some(rec) if is_active(rec) => is_registrar(rec) || !actor_has_registrar(me, &rec.actor),
        _ => false,
    }
}

/// Is the lobby Welcome's sender (`from`) a sibling — not me, active on my chain, same actor?
pub fn is_sibling(from: Option<&str>, me: Option<&MeInfo>, actor: Option<&str>, device: &str) -> bool {
    let (Some(from), Some(actor)) = (from, actor) else { return false };
    if from.is_empty() || from == device || actor.is_empty() {
        return false;
    }
    record_of(me, from).map_or(false, |rec| rec.actor == actor && is_active(rec))
}

fn is_hex64(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// Is a mailbox row of my actor and well formed (lowercase 64-hex key and fingerprint)?
pub fn is_candidate_for(c: &CandidateView, actor: &str) -> bool {
    c.actor == actor && is_hex64(&c.signing_key) && is_hex64(&c.fingerprint)
}

/// The mailbox rows an approver of `actor` may act on, in mailbox order.
pub fn candidates_for<'a>(list: &'a [CandidateView], actor: &str) -> Vec<&'a CandidateView> {
    list.iter().filter(|c| is_candidate_for(c, actor)).collect()
}

/// `roles` with registrar added or removed, as the **complete sorted** list the server's
/// CanonicalRoles expects (duplicates collapse).
pub fn next_roles(roles: &[String], grant: bool) -> Vec<String> {
    let mut out: Vec<String> = roles.iter().filter(|r| *r != ROLE_REGISTRAR).cloned().collect();
    if grant {
        out.push(ROLE_REGISTRAR.to_owned());
    }
    out.sort();
    out.dedup();
    out
}

/// One row of 「내 기기」: what this device may change on that record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceRow {
    pub device_id: String,
    pub registrar: bool,
    pub is_self: bool,
    /// Grant registrar: can sign · target active · same actor · not yet a registrar.
    pub grant: bool,
    /// Release registrar: can sign · target active · same actor · registrar · another active
    /// registrar remains.
    pub release: bool,
    /// Releasing would leave the actor without a registrar — grant another device first.
    pub last_registrar: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RolesView {
    /// [`can_approve`] (E5 follows the same rule).
    pub can_sign: bool,
    /// This device's actor (`None` without a chain record).
    pub actor: Option<String>,
    /// Every record of the subject (revoked too), **in chain order** — a host that lists this
    /// device first sorts on `is_self` itself.
    pub devices: Vec<DeviceRow>,
}

/// The roles each chain record could get from this device.
pub fn roles_actions(me: Option<&MeInfo>, device: &str) -> RolesView {
    let all: &[MeDevice] = me.map_or(&[], |m| m.devices.as_slice());
    let can_sign = can_approve(me, device);
    let actor = record_of(me, device).map(|d| d.actor.clone());
    let active_registrars = all
        .iter()
        .filter(|d| Some(&d.actor) == actor.as_ref() && is_active(d) && is_registrar(d))
        .count();
    let devices = all
        .iter()
        .map(|d| {
            let registrar = is_registrar(d);
            let eligible = can_sign && is_active(d) && Some(&d.actor) == actor.as_ref();
            let release = eligible && registrar && active_registrars > 1;
            DeviceRow {
                device_id: d.device_id.clone(),
                registrar,
                is_self: d.device_id == device,
                grant: eligible && !registrar,
                release,
                last_registrar: eligible && registrar && !release,
            }
        })
        .collect();
    RolesView { can_sign, actor, devices }
}

/// A room as the sibling-invite rule sees it: `pending` = my invite commit is not echoed yet,
/// `roster` = the group's members (`None` when unknown).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InviteRoom {
    pub room: String,
    pub joined: bool,
    pub halted: bool,
    pub pending: bool,
    pub roster: Option<Vec<String>>,
}

/// Rooms to invite a new sibling into: joined, not halted, no pending commit of mine and —
/// when `target` is given — the target not already on the roster. Input order is kept.
pub fn sibling_invite_rooms(rooms: &[InviteRoom], target: Option<&str>) -> Vec<String> {
    rooms
        .iter()
        .filter(|r| r.joined && !r.halted && !r.pending)
        .filter(|r| match (target, &r.roster) {
            (Some(t), Some(roster)) => !roster.iter().any(|m| m == t),
            _ => true,
        })
        .map(|r| r.room.clone())
        .collect()
}

/// Candidate-post answer → enrollment mode (`code` = the error envelope's `error`, empty if none).
pub fn enroll_mode_from(status: u16, code: &str) -> EnrollMode {
    match (status, code) {
        (201, _) => EnrollMode::Sibling,
        (409, "device_exists") => EnrollMode::IdTaken,
        _ => EnrollMode::Operator,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn fixture() -> Value {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/fixtures/self-service-vectors.json");
        serde_json::from_str(&std::fs::read_to_string(path).expect("self-service-vectors.json")).expect("valid json")
    }

    fn me_of(f: &Value, case: &Value) -> Option<MeInfo> {
        case["me"].as_str().map(|k| serde_json::from_value(f["mes"][k].clone()).expect("me record"))
    }

    fn cases<'a>(f: &'a Value, key: &str) -> &'a Vec<Value> {
        let v = f[key].as_array().unwrap_or_else(|| panic!("{key} missing"));
        assert!(!v.is_empty(), "{key} empty");
        v
    }

    #[test]
    fn constants_match_the_vectors() {
        let c = &fixture()["constants"];
        assert_eq!(c["role_registrar"], ROLE_REGISTRAR);
        assert_eq!(c["status_active"], STATUS_ACTIVE);
        assert_eq!(c["sibling_invite_ttl_ms"], SIBLING_INVITE_TTL_MS);
        assert_eq!(c["sibling_lobby_recheck_ms"], SIBLING_LOBBY_RECHECK_MS);
        assert_eq!(c["candidate_repost_margin_ms"], CANDIDATE_REPOST_MARGIN_MS);
        assert_eq!(c["candidate_ttl_seconds"], CANDIDATE_TTL_SECONDS);
    }

    #[test]
    fn shared_vectors() {
        let f = fixture();
        for c in cases(&f, "actor_has_registrar") {
            let me = me_of(&f, c);
            assert_eq!(actor_has_registrar(me.as_ref(), c["actor"].as_str().unwrap()), c["expect"], "{}", c["name"]);
        }
        for c in cases(&f, "can_approve") {
            let me = me_of(&f, c);
            assert_eq!(can_approve(me.as_ref(), c["device"].as_str().unwrap()), c["expect"], "{}", c["name"]);
        }
        for c in cases(&f, "is_sibling") {
            let me = me_of(&f, c);
            let got = is_sibling(c["from"].as_str(), me.as_ref(), c["actor"].as_str(), c["device"].as_str().unwrap());
            assert_eq!(got, c["expect"], "{}", c["name"]);
        }
        for c in cases(&f, "candidates_for") {
            let list: Vec<CandidateView> = serde_json::from_value(c["candidates"].clone()).unwrap();
            let got: Vec<&str> = candidates_for(&list, c["actor"].as_str().unwrap()).iter().map(|c| c.device_id.as_str()).collect();
            let want: Vec<&str> = c["expect"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
            assert_eq!(got, want, "{}", c["name"]);
        }
        for c in cases(&f, "next_roles") {
            let roles: Vec<String> = serde_json::from_value(c["roles"].clone()).unwrap();
            let want: Vec<String> = serde_json::from_value(c["expect"].clone()).unwrap();
            assert_eq!(next_roles(&roles, c["grant"].as_bool().unwrap()), want, "{c}");
        }
        for c in cases(&f, "roles_actions") {
            let me = me_of(&f, c);
            let v = roles_actions(me.as_ref(), c["device"].as_str().unwrap());
            let e = &c["expect"];
            assert_eq!(v.can_sign, e["can_sign"], "{}", c["name"]);
            assert_eq!(v.actor.as_deref(), e["actor"].as_str(), "{}", c["name"]);
            let rows: Vec<Value> = v
                .devices
                .iter()
                .map(|d| {
                    serde_json::json!({"device_id": d.device_id, "registrar": d.registrar, "is_self": d.is_self,
                        "grant": d.grant, "release": d.release, "last_registrar": d.last_registrar})
                })
                .collect();
            assert_eq!(Value::Array(rows), e["devices"], "{}", c["name"]);
        }
        for c in cases(&f, "sibling_invite_rooms") {
            let rooms: Vec<InviteRoom> = c["rooms"]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| InviteRoom {
                    room: r["room"].as_str().unwrap().to_owned(),
                    joined: r["joined"].as_bool().unwrap(),
                    halted: r["halted"].as_bool().unwrap(),
                    pending: r["pending"].as_bool().unwrap(),
                    roster: serde_json::from_value(r["roster"].clone()).unwrap(),
                })
                .collect();
            let want: Vec<String> = serde_json::from_value(c["expect"].clone()).unwrap();
            assert_eq!(sibling_invite_rooms(&rooms, c["target"].as_str()), want, "{}", c["name"]);
        }
        for c in cases(&f, "enroll_mode") {
            let got = match enroll_mode_from(c["status"].as_u64().unwrap() as u16, c["code"].as_str().unwrap()) {
                EnrollMode::Sibling => "sibling",
                EnrollMode::IdTaken => "id-taken",
                EnrollMode::Operator => "operator",
            };
            assert_eq!(got, c["expect"], "{c}");
        }
    }
}
