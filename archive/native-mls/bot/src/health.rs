//! #426 bot-side signal: `<rooms-dir>/health.json`, a node-local projection of
//! what the steward otherwise only says on stdout (journal) — relay
//! reachability, the last 403, and each room's `halted`/`pending` state — so
//! doctor/fleet-watch (ccc-node#2380 ⑥) can read it without scraping logs.
//!
//! - Written atomically (tmp + rename, mode 0640) when a watched field changes
//!   and otherwise every [`HEARTBEAT`], so a reader can tell a stuck loop or an
//!   old binary (`updated` stale / no file) from a healthy one.
//! - No secrets, no message text, no relay address: errors are reduced to a
//!   class ([`error_class`]).
//! - The halt marker (`<room>.state.refused`) stays the source of truth;
//!   `halt_reason` is copied from it at write time.
//! - Best effort: a failed write never takes the session down (the caller
//!   logs it once).

use crate::api::BotError;
use native_mls_host::http::HttpError;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// File name inside the steward's `--rooms-dir`.
pub const FILE: &str = "health.json";
/// Schema version of the file (bumped on an incompatible change).
pub const VERSION: u32 = 1;
/// Rewrite at least this often while nothing changes (readers treat a file
/// older than ~5 min as stale).
pub const HEARTBEAT: Duration = Duration::from_secs(30);

/// One room as the health file shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoomHealth {
    pub room: String,
    pub joined: bool,
    pub mode: &'static str,
    pub halted: bool,
    /// #814: the relay answers 404 `no_such_room` for a room it showed before.
    pub relay_missing: bool,
    pub pending: bool,
    pub cursor: i64,
    pub epoch: i64,
    /// The room's halt marker, read for `halt_reason` only when written.
    pub marker: Option<PathBuf>,
}

/// What a change is judged on: cursor/epoch/attempts move all the time and
/// ride on the heartbeat instead of forcing a write each.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Key {
    relay_up: bool,
    class: Option<&'static str>,
    last_403: Option<(String, u64)>,
    rooms: Vec<(String, bool, &'static str, bool, bool, bool)>,
}

pub struct Health {
    path: PathBuf,
    device: String,
    pid: u32,
    started: u64,
    relay_up: bool,
    since: u64,
    attempts: u32,
    last_error_class: Option<&'static str>,
    /// Transitions to unreachable since this process started.
    outages: u64,
    last_403: Option<(String, u64)>,
    written: Option<(Key, Instant)>,
    failure_announced: bool,
}

/// The class of a relay error, never its text (no address, no body).
pub fn error_class(err: &BotError) -> &'static str {
    use std::io::ErrorKind;
    match err {
        BotError::Http(HttpError::Io(e)) => match e.kind() {
            ErrorKind::ConnectionRefused => "refused",
            // `TcpStream::connect_timeout` → "connection timed out".
            ErrorKind::TimedOut => "timeout",
            // A read timeout on Linux surfaces as EAGAIN.
            ErrorKind::WouldBlock => "read_timeout",
            ErrorKind::ConnectionReset | ErrorKind::ConnectionAborted | ErrorKind::BrokenPipe | ErrorKind::UnexpectedEof => "reset",
            _ => "io",
        },
        BotError::Http(HttpError::BadResponse(_)) => "protocol",
        BotError::Status { status } | BotError::Api { status, .. } if (502..=504).contains(status) => "gateway",
        _ => "other",
    }
}

pub fn unix_now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl Health {
    /// `rooms_dir/health.json` for `device`. A previous file of the same
    /// device hands over its `last_403`: a 403 in the loop ends the process,
    /// and the restarted one must still show it.
    pub fn open(rooms_dir: &Path, device: &str, now_unix: u64) -> Health {
        let path = rooms_dir.join(FILE);
        let last_403 = std::fs::read(&path)
            .ok()
            .and_then(|raw| serde_json::from_slice::<serde_json::Value>(&raw).ok())
            .filter(|prev| prev["device"] == device)
            .and_then(|prev| {
                let l = &prev["access"]["last_403"];
                Some((l["code"].as_str()?.to_string(), l["at"].as_u64()?))
            });
        Health {
            path, device: device.to_string(), pid: std::process::id(), started: now_unix,
            relay_up: true, since: now_unix, attempts: 0, last_error_class: None, outages: 0,
            last_403, written: None, failure_announced: false,
        }
    }

    pub fn path(&self) -> &Path { &self.path }

    /// A round that could not reach the relay (`attempt` = consecutive count).
    pub fn relay_unreachable(&mut self, err: &BotError, attempt: u32, now_unix: u64) {
        if self.relay_up {
            self.relay_up = false;
            self.since = now_unix;
            self.outages += 1;
        }
        self.attempts = attempt;
        self.last_error_class = Some(error_class(err));
    }

    /// The relay answered again. `last_error_class` keeps the outage's class.
    pub fn relay_reachable(&mut self, now_unix: u64) {
        if !self.relay_up {
            self.relay_up = true;
            self.since = now_unix;
        }
        self.attempts = 0;
    }

    /// Remember a 403 (any code); other errors are ignored.
    pub fn record_error(&mut self, err: &BotError, now_unix: u64) {
        let code = match err {
            BotError::Api { status: 403, code } => code.clone(),
            BotError::Status { status: 403 } => "forbidden".to_string(),
            _ => return,
        };
        self.last_403 = Some((code, now_unix));
    }

    fn key(&self, rooms: &[RoomHealth]) -> Key {
        Key {
            relay_up: self.relay_up,
            class: self.last_error_class,
            last_403: self.last_403.clone(),
            rooms: rooms.iter().map(|r| (r.room.clone(), r.joined, r.mode, r.halted, r.relay_missing, r.pending)).collect(),
        }
    }

    /// The file body (schema v1).
    pub fn body(&self, rooms: &[RoomHealth], now_unix: u64) -> serde_json::Value {
        serde_json::json!({
            "version": VERSION,
            "device": self.device,
            "pid": self.pid,
            "started": self.started,
            "updated": now_unix,
            "relay": {
                "state": if self.relay_up { "up" } else { "unreachable" },
                "since": self.since,
                "attempts": self.attempts,
                "last_error_class": self.last_error_class,
                "outages": self.outages,
            },
            "access": {
                "last_403": self.last_403.as_ref().map(|(code, at)| serde_json::json!({"code": code, "at": at})),
            },
            "rooms": rooms.iter().map(|r| serde_json::json!({
                "room": r.room, "joined": r.joined, "mode": r.mode, "halted": r.halted,
                "halt_reason": if r.halted { r.marker.as_deref().and_then(halt_reason) } else { None },
                "relay_missing": r.relay_missing, "pending": r.pending, "cursor": r.cursor, "epoch": r.epoch,
            })).collect::<Vec<_>>(),
        })
    }

    /// Write the file when a watched field changed or the heartbeat is due.
    /// `Ok(true)` = written. On `Err` the next call tries again.
    pub fn observe(&mut self, rooms: &[RoomHealth], now_unix: u64, now: Instant) -> Result<bool, BotError> {
        let key = self.key(rooms);
        let due = match &self.written {
            None => true,
            Some((last, at)) => *last != key || now.saturating_duration_since(*at) >= HEARTBEAT,
        };
        if !due {
            return Ok(false);
        }
        let raw = serde_json::to_vec(&self.body(rooms, now_unix)).map_err(|_| BotError::Local("health json"))?;
        write_atomic(&self.path, &raw)?;
        self.written = Some((key, now));
        Ok(true)
    }

    /// True the first time only: a broken health path is logged once.
    pub fn announce_failure(&mut self) -> bool {
        !std::mem::replace(&mut self.failure_announced, true)
    }
}

/// `reason` of a halt marker; an unreadable marker reads as `unreadable`
/// (the room still halts, as at startup).
fn halt_reason(marker: &Path) -> Option<String> {
    let raw = std::fs::read(marker).ok()?;
    Some(
        serde_json::from_slice::<serde_json::Value>(&raw)
            .ok()
            .and_then(|m| m.get("reason").and_then(|r| r.as_str()).map(str::to_string))
            .unwrap_or_else(|| "unreadable".to_string()),
    )
}

/// tmp + rename so a reader sees the old or the new file, never half of one.
fn write_atomic(path: &Path, raw: &[u8]) -> Result<(), BotError> {
    let mut tmp = path.as_os_str().to_os_string();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    let _ = std::fs::remove_file(&tmp);
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o640);
    }
    let mut file = options.open(&tmp).map_err(|_| BotError::Local("health file create"))?;
    // Explicit: a 0077 umask would otherwise leave the root-only 0600 and the
    // body holds nothing secret.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o640)).map_err(|_| BotError::Local("health file chmod"))?;
    }
    file.write_all(raw).map_err(|_| BotError::Local("health file write"))?;
    file.sync_all().map_err(|_| BotError::Local("health file fsync"))?;
    drop(file);
    std::fs::rename(&tmp, path).map_err(|_| BotError::Local("health file rename"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("native-mls-bot-health-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).expect("dir");
        d
    }

    fn room(name: &str, halted: bool, marker: Option<PathBuf>) -> RoomHealth {
        RoomHealth { room: name.into(), joined: true, mode: "agent", halted, relay_missing: false, pending: false, cursor: 7, epoch: 2, marker }
    }

    fn io(kind: std::io::ErrorKind) -> BotError { BotError::Http(HttpError::Io(std::io::Error::from(kind))) }

    fn read(path: &Path) -> serde_json::Value {
        serde_json::from_slice(&std::fs::read(path).expect("health file")).expect("json")
    }

    #[test]
    fn error_classes_never_carry_text() {
        use std::io::ErrorKind::*;
        assert_eq!(error_class(&io(ConnectionRefused)), "refused");
        assert_eq!(error_class(&io(TimedOut)), "timeout");
        assert_eq!(error_class(&io(WouldBlock)), "read_timeout");
        assert_eq!(error_class(&io(ConnectionReset)), "reset");
        assert_eq!(error_class(&io(UnexpectedEof)), "reset");
        assert_eq!(error_class(&io(PermissionDenied)), "io");
        assert_eq!(error_class(&BotError::Http(HttpError::BadResponse("no header terminator"))), "protocol");
        assert_eq!(error_class(&BotError::Status { status: 503 }), "gateway");
        assert_eq!(error_class(&BotError::Api { status: 502, code: "x".into() }), "gateway");
        assert_eq!(error_class(&BotError::Status { status: 500 }), "other");
    }

    /// Schema v1: every documented field, the right types, no extra secrets.
    #[test]
    fn body_matches_schema_v1() {
        let d = dir("schema");
        let marker = d.join("family.state.refused");
        std::fs::write(&marker, br#"{"room":"family","reason":"history_gap"}"#).unwrap();
        let mut h = Health::open(&d, "bot-1", 100);
        h.relay_unreachable(&io(std::io::ErrorKind::TimedOut), 3, 110);
        h.record_error(&BotError::Api { status: 403, code: "device_subject_mismatch".into() }, 105);
        let body = h.body(&[room("family", true, Some(marker)), room("ops", false, None)], 120);
        assert_eq!(body["version"], 1);
        assert_eq!(body["device"], "bot-1");
        assert_eq!(body["started"], 100);
        assert_eq!(body["updated"], 120);
        assert!(body["pid"].is_u64());
        assert_eq!(body["relay"], serde_json::json!({"state":"unreachable","since":110,"attempts":3,"last_error_class":"timeout","outages":1}));
        assert_eq!(body["access"]["last_403"], serde_json::json!({"code":"device_subject_mismatch","at":105}));
        assert_eq!(body["rooms"][0], serde_json::json!({"room":"family","joined":true,"mode":"agent","halted":true,"halt_reason":"history_gap","relay_missing":false,"pending":false,"cursor":7,"epoch":2}));
        assert_eq!(body["rooms"][1]["halt_reason"], serde_json::Value::Null);
        let keys: Vec<_> = body.as_object().unwrap().keys().cloned().collect();
        assert_eq!(keys.len(), 8, "{keys:?}");
    }

    /// up → unreachable → up: `since` moves only on a transition, the outage
    /// count once per outage, the class survives recovery.
    #[test]
    fn relay_transitions() {
        let d = dir("transitions");
        let mut h = Health::open(&d, "bot-1", 100);
        let refused = io(std::io::ErrorKind::ConnectionRefused);
        h.relay_unreachable(&refused, 1, 200);
        h.relay_unreachable(&refused, 2, 201);
        let b = h.body(&[], 202);
        assert_eq!((b["relay"]["state"].as_str(), b["relay"]["since"].as_u64(), b["relay"]["attempts"].as_u64()), (Some("unreachable"), Some(200), Some(2)));
        h.relay_reachable(210);
        h.relay_reachable(211);
        let b = h.body(&[], 212);
        assert_eq!(b["relay"], serde_json::json!({"state":"up","since":210,"attempts":0,"last_error_class":"refused","outages":1}));
        h.relay_unreachable(&io(std::io::ErrorKind::TimedOut), 1, 300);
        assert_eq!(h.body(&[], 301)["relay"]["outages"], 2);
    }

    /// Written at once on the first call and on a change; otherwise only when
    /// the heartbeat is due. Cursor movement alone does not force a write.
    #[test]
    fn writes_on_change_and_heartbeat_only() {
        let d = dir("throttle");
        let mut h = Health::open(&d, "bot-1", 100);
        let t0 = Instant::now();
        let mut rooms = vec![room("family", false, None)];
        assert!(h.observe(&rooms, 100, t0).unwrap(), "first call writes");
        rooms[0].cursor = 9;
        assert!(!h.observe(&rooms, 101, t0 + Duration::from_secs(1)).unwrap(), "cursor alone waits for the heartbeat");
        assert_eq!(read(h.path())["rooms"][0]["cursor"], 7);
        h.relay_unreachable(&io(std::io::ErrorKind::TimedOut), 1, 102);
        assert!(h.observe(&rooms, 102, t0 + Duration::from_secs(2)).unwrap(), "a relay transition writes");
        let v = read(h.path());
        assert_eq!((v["relay"]["state"].as_str(), v["rooms"][0]["cursor"].as_i64()), (Some("unreachable"), Some(9)));
        h.relay_unreachable(&io(std::io::ErrorKind::TimedOut), 2, 103);
        assert!(!h.observe(&rooms, 103, t0 + Duration::from_secs(3)).unwrap(), "another attempt is not a transition");
        rooms[0].halted = true;
        assert!(h.observe(&rooms, 104, t0 + Duration::from_secs(4)).unwrap(), "a halt writes");
        assert!(!h.observe(&rooms, 105, t0 + Duration::from_secs(5)).unwrap());
        assert!(h.observe(&rooms, 140, t0 + Duration::from_secs(4) + HEARTBEAT).unwrap(), "heartbeat");
        assert_eq!(read(h.path())["updated"], 140);
        // #814: a room the relay lost is a transition too, and so is its return.
        rooms[0].relay_missing = true;
        assert!(h.observe(&rooms, 141, t0 + Duration::from_secs(5) + HEARTBEAT).unwrap(), "relay_missing writes");
        assert_eq!(read(h.path())["rooms"][0]["relay_missing"], true);
        rooms[0].relay_missing = false;
        assert!(h.observe(&rooms, 142, t0 + Duration::from_secs(6) + HEARTBEAT).unwrap(), "its return writes");
        assert_eq!(read(h.path())["rooms"][0]["relay_missing"], false);
    }

    /// Atomic: no tmp left behind, mode 0640, the old file replaced whole.
    #[test]
    fn write_is_atomic_with_mode_0640() {
        let d = dir("atomic");
        let mut h = Health::open(&d, "bot-1", 100);
        std::fs::write(d.join("health.json.tmp"), b"stale tmp").unwrap();
        h.observe(&[room("family", false, None)], 100, Instant::now()).unwrap();
        assert!(!d.join("health.json.tmp").exists(), "tmp renamed away");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(h.path()).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o640);
        }
        assert_eq!(read(h.path())["version"], 1);
    }

    /// A 403 survives the restart it causes (same device only); other
    /// errors are not recorded.
    #[test]
    fn last_403_carries_over_a_restart() {
        let d = dir("carry");
        let mut h = Health::open(&d, "bot-1", 100);
        h.record_error(&BotError::Status { status: 503 }, 101);
        h.record_error(&BotError::Api { status: 403, code: "device_not_allowed".into() }, 102);
        h.observe(&[], 102, Instant::now()).unwrap();
        let again = Health::open(&d, "bot-1", 200);
        assert_eq!(again.body(&[], 200)["access"]["last_403"], serde_json::json!({"code":"device_not_allowed","at":102}));
        let other = Health::open(&d, "bot-2", 200);
        assert_eq!(other.body(&[], 200)["access"]["last_403"], serde_json::Value::Null, "another device's file is not inherited");
    }

    #[test]
    fn unreadable_marker_still_reports_halted() {
        let d = dir("marker");
        let marker = d.join("family.state.refused");
        std::fs::write(&marker, b"not json").unwrap();
        let h = Health::open(&d, "bot-1", 100);
        assert_eq!(h.body(&[room("family", true, Some(marker))], 100)["rooms"][0]["halt_reason"], "unreadable");
    }

    #[test]
    fn failure_is_announced_once() {
        let d = dir("announce");
        let mut h = Health::open(&d.join("missing-dir"), "bot-1", 100);
        assert!(h.observe(&[], 100, Instant::now()).is_err());
        assert!(h.announce_failure());
        assert!(!h.announce_failure());
    }
}
