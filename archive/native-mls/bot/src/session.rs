//! M5 step 2 (#177 §7): the room session. `session <room> <device>
//! [<watch-room>]` publishes one key package, then long-polls the relay like
//! any other leaf:
//!
//! ```text
//! GET events?after=cursor → welcome (join) → commit (apply) → application
//!   (decrypt + echo-reply) → own events skipped
//! ```
//!
//! Contract notes carried over from the smoke references:
//! - Attribution (review H1): the bot has no pin map, so it encrypts with
//!   `client_id == device identity` and its `decrypt` rejects any sender whose
//!   AAD client_id is not the sender's own roster identity. The relay's
//!   per-device `client_id` POST field is a separate dedup key (`<device>-echo-n`).
//! - The room's first commit seeds its actor roster, so a bot actor must be in
//!   the creation commit — the harness invites it together with the other
//!   founding member; the bot itself never commits.
//! - A 409 (`cas_mismatch`) means the room moved under us: resynchronize on
//!   the next poll, then replay the dropped echo once at the fresh epoch.
//! - Events before our Welcome are not ours to read; a Welcome delivered by
//!   the relay is always targeted at us (server-side filter), so a second one
//!   is a contract violation.

use crate::api::{self, BotError, Client, EventPost, StoredRow};
use family_mls_browser_experiment::Device;
use std::io::Write;
use std::time::{Duration, Instant};

/// Backstop so a stuck session can never hang CI: the harness normally
/// SIGTERMs the bot long before this.
const DEFAULT_MAX_SECS: u64 = 300;
const POLL: Duration = Duration::from_millis(200);
/// One status heartbeat per second of polling keeps the harness (and CI logs)
/// informed without flooding stdout.
const STATUS_EVERY: u32 = 5;

pub struct Options {
    pub base: String,
    pub room: String,
    pub device: String,
    pub watch_room: Option<String>,
    /// Caller auth for `-access-mode required` relays: every request carries
    /// the CF Access assertion from this source (see `api::Access`).
    pub access: api::Access,
    /// Persistent identity state file (`--state-file`): when present the bot
    /// resumes its MLS identity and room cursor across restarts instead of
    /// becoming a new device every run.
    pub state_file: Option<std::path::PathBuf>,
}

/// On-disk envelope around the facade's `export_state` snapshot (M5 후속):
/// the bot binds the snapshot to its room and device and tracks the relay
/// cursor/epoch so a restart resumes exactly where it stopped.
#[derive(serde::Serialize, serde::Deserialize)]
struct StateEnvelope {
    version: u32,
    room: String,
    device: String,
    cursor: i64,
    epoch: i64,
    joined: bool,
    /// Application echoes sent so far: the relay dedups POSTs by
    /// `<device>-echo-<n>`, so a restart must not restart that counter.
    echoes: u64,
    /// `Device::export_state` JSON (identity-bound inside).
    state: serde_json::Value,
}

const STATE_VERSION: u32 = 1;

/// Read the state file, if configured. Missing → fresh device. A file that
/// exists but fails to load fails the session (fail-closed): silently
/// starting a fresh identity would strand the enrollment and the group
/// membership behind it.
fn load_state(
    path: Option<&std::path::Path>, room: &str, device: &str,
) -> Result<Option<(Device, i64, i64, bool, u64)>, BotError> {
    let Some(path) = path else { return Ok(None) };
    let raw = match std::fs::read(path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(BotError::Local("state file unreadable")),
    };
    let env: StateEnvelope =
        serde_json::from_slice(&raw).map_err(|_| BotError::Local("state file corrupt"))?;
    if env.version != STATE_VERSION || env.room != room || env.device != device {
        return Err(BotError::Local("state file is for another version/room/device"));
    }
    let state = serde_json::to_vec(&env.state).map_err(|_| BotError::Local("state file corrupt"))?;
    let dev = Device::import_state(device, &state)
        .map_err(|_| BotError::Local("state import rejected"))?;
    Ok(Some((dev, env.cursor, env.epoch, env.joined, env.echoes)))
}

/// Atomic write (tmp + rename, 0600): a torn state file must never be the one
/// a restart reads.
fn persist_state(
    path: &std::path::Path, room: &str, device: &str, dev: &mut Device,
    cursor: i64, epoch: i64, joined: bool, echoes: u64,
) -> Result<(), BotError> {
    let bytes = dev.export_state(device).map_err(|_| BotError::Local("state export rejected"))?;
    let env = StateEnvelope {
        version: STATE_VERSION,
        room: room.to_string(),
        device: device.to_string(),
        cursor,
        epoch,
        joined,
        echoes,
        state: serde_json::from_slice(&bytes).map_err(|_| BotError::Local("state export json"))?,
    };
    let raw = serde_json::to_vec(&env).map_err(|_| BotError::Local("state envelope json"))?;
    let tmp = path.with_extension("state.tmp");
    std::fs::write(&tmp, &raw).map_err(|_| BotError::Local("state file write"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, path).map_err(|_| BotError::Local("state file rename"))?;
    Ok(())
}

struct RoomState {
    room: String,
    cursor: i64,
    epoch: i64,
    joined: bool,
    /// Application messages decrypted and echoed back.
    echoes: u64,
    /// Set on 409: the next poll resynchronizes, then replays this plaintext.
    retry: Option<Vec<u8>>,
    /// MLS state moved since the last state-file snapshot (join, commit,
    /// echo encrypt): the poll loop flushes it before the next round.
    dirty: bool,
}

pub fn run(opts: Options) -> Result<(), BotError> {
    let max_secs = std::env::var("NATIVE_MLS_BOT_MAX_SECS")
        .ok()
        .and_then(|raw| raw.parse().ok())
        .unwrap_or(DEFAULT_MAX_SECS);
    let deadline = Instant::now() + Duration::from_secs(max_secs);
    let client = Client::with_access(&opts.base, opts.access.clone());

    let mut restored_main: Option<(i64, i64, bool, u64)> = None;
    let mut device = match load_state(opts.state_file.as_deref(), &opts.room, &opts.device)? {
        Some((dev, cursor, epoch, joined, echoes)) => {
            restored_main = Some((cursor, epoch, joined, echoes));
            dev
        }
        None => Device::new(&opts.device)
            .map_err(|_| BotError::Local("device new: identity shape rejected"))?,
    };
    let key_package = device
        .key_package()
        .map_err(|_| BotError::Local("key package generation"))?;
    let public_key = device
        .public_key()
        .map_err(|_| BotError::Local("public key"))?;
    // First line, before any relay write: the harness enrolls the bot actor
    // with this public key (the policy chain gates every POST). A resumed
    // device announces the same key it enrolled with, so no re-enrollment
    // happens — `restored` says which one this is.
    emit(&serde_json::json!({
        "event": "identity",
        "device": opts.device,
        "room": opts.room,
        "watch_room": opts.watch_room,
        "public_key": hex(&public_key),
        "restored": restored_main.is_some(),
    }));
    // Persist the fresh identity before its first key package leaves the
    // process: a crash between publish and the first snapshot must not leave
    // a relay package whose private material no device holds. A resumed
    // device keeps its on-disk state instead — rewriting zeroes here would
    // regress the cursor/join the restart is meant to resume.
    if let (Some(path), None) = (opts.state_file.as_deref(), restored_main) {
        persist_state(path, &opts.room, &opts.device, &mut device, 0, 0, false, 0)?;
    }
    let mut auth_wait_announced = false;
    let key_ref = api::ref_hex(&key_package);
    let stored = 'publish: loop {
        match client.post_key_packages(&opts.room, &opts.device, &[(&key_ref, key_package.clone())]) {
            Ok(stored) => break 'publish stored,
            // With -device-state on, every POST needs an active policy device:
            // the harness enrolls us from the `identity` line below, so the
            // first attempts may legitimately land before that. Retry. With
            // -access-mode required the identity line answers an *unknown*
            // device with the same opaque 403 device_subject_mismatch (the
            // relay refuses to reveal which of unknown/wrong-subject it was),
            // so pre-enrollment attempts surface under that code too.
            Err(BotError::Api { status: 403, code })
                if code == "device_not_allowed" || code == "device_subject_mismatch" =>
            {
                std::thread::sleep(POLL);
                if Instant::now() >= deadline {
                    return Err(BotError::Local("session deadline exceeded waiting for enrollment"));
                }
            }
            // With -access-mode required, a short-lived assertion can lapse
            // while we wait for enrollment: wait for the token file to be
            // rotated instead of dying.
            Err(BotError::Api { status: 401, .. } | BotError::Status { status: 401 }) => {
                if !auth_wait_announced {
                    auth_wait_announced = true;
                    emit(&serde_json::json!({
                        "event": "auth_wait",
                        "room": opts.room,
                        "device": opts.device,
                    }));
                }
                std::thread::sleep(POLL);
                if Instant::now() >= deadline {
                    return Err(BotError::Local("session deadline exceeded waiting for an access token"));
                }
            }
            Err(err) => return Err(err),
        }
    };
    if stored != 1 {
        return Err(BotError::Local("relay stored an unexpected key package count"));
    }
    emit(&serde_json::json!({
        "event": "ready",
        "device": opts.device,
        "room": opts.room,
        "watch_room": opts.watch_room,
        // Ed25519 public key hex: the harness enrolls the bot actor with it.
        "public_key": hex(&public_key),
        "key_ref": key_ref,
        "max_secs": max_secs,
    }));

    let (c0, e0, j0, x0) = restored_main.unwrap_or((0, 0, false, 0));
    let mut rooms = vec![RoomState {
        room: opts.room.clone(), cursor: c0, epoch: e0, joined: j0, echoes: x0, retry: None, dirty: false,
    }];
    if let Some(watch) = &opts.watch_room {
        // The negative control: a room the bot is never invited to. It must
        // stay unjoined and silent there for the whole session.
        rooms.push(RoomState {
            room: watch.clone(), cursor: 0, epoch: 0, joined: false, echoes: 0, retry: None, dirty: false,
        });
    }

    let mut rounds = 0u32;
    let mut auth_wait_announced = false;
    loop {
        if Instant::now() >= deadline {
            return Err(BotError::Local("session deadline exceeded"));
        }
        for state in &mut rooms {
            match poll_room(&client, &mut device, &opts.device, state) {
                Ok(()) => {}
                // 401 = the assertion expired or was rejected. The token file
                // may already carry a rotated token (or will soon): keep
                // polling until the deadline instead of dying, and say why
                // once so the harness can tell an auth wait from a hang.
                Err(err @ (BotError::Api { status: 401, .. } | BotError::Status { status: 401 })) => {
                    if !auth_wait_announced {
                        auth_wait_announced = true;
                        emit(&serde_json::json!({
                            "event": "auth_wait",
                            "room": state.room,
                            "device": opts.device,
                        }));
                    }
                    let _ = err;
                }
                Err(err) => return Err(err),
            }
        }
        // MLS state that moved this round goes to disk before the next poll:
        // a restart must resume from exactly this cursor or it cannot decrypt
        // (the group ratchets on). A persist failure takes the session down —
        // running on unpersisted state would fork the identity silently.
        if let Some(path) = opts.state_file.as_deref() {
            if rooms[0].dirty {
                persist_state(path, &opts.room, &opts.device, &mut device,
                              rooms[0].cursor, rooms[0].epoch, rooms[0].joined, rooms[0].echoes)?;
                rooms[0].dirty = false;
            }
        }
        rounds += 1;
        if rounds % STATUS_EVERY == 0 {
            status(&rooms);
        }
        std::thread::sleep(POLL);
    }
}

fn poll_room(client: &Client, device: &mut Device, own: &str, state: &mut RoomState) -> Result<(), BotError> {
    let body = match client.get_events(&state.room, own, state.cursor) {
        Ok(body) => body,
        // The watch room may not exist yet (its founding commit has not been
        // posted) — that is not an error, just nothing to see.
        Err(BotError::Api { status: 404, code }) if code == "no_such_room" => return Ok(()),
        Err(err) => return Err(err),
    };
    state.epoch = body.epoch;
    for ev in &body.events {
        state.cursor = state.cursor.max(ev.seq);
        if ev.device == own {
            // Own echo. MLS never processes its own messages; when this bot
            // ever POSTs a commit, its echo is where merge_pending belongs.
            continue;
        }
        match ev.kind.as_str() {
            "welcome" if !state.joined => {
                device.join(&ev.bytes).map_err(|_| BotError::Local("join welcome"))?;
                state.joined = true;
                state.dirty = true;
                emit(&serde_json::json!({
                    "event": "joined", "room": state.room, "epoch": ev.epoch, "seq": ev.seq,
                }));
            }
            // The relay filters welcomes to their targets only: any welcome
            // that reaches us here would mean we already joined once.
            "welcome" => return Err(BotError::Local("unexpected second welcome")),
            "commit" if state.joined => {
                device.apply_commit(&ev.bytes).map_err(|_| BotError::Local("apply commit"))?;
                state.dirty = true;
            }
            "application" if state.joined => echo(client, device, own, state, ev)?,
            // Everything before our Welcome (commits that formed the group,
            // other members' applications) is not ours to read.
            _ => {}
        }
    }
    if let (true, Some(plaintext)) = (state.joined, state.retry.take()) {
        publish_echo(client, device, own, state, &plaintext)
            .map_err(|err| report_dropped(state, &plaintext, err))?;
    }
    Ok(())
}

/// Decrypt one application event and reply with the identical plaintext.
fn echo(client: &Client, device: &mut Device, own: &str, state: &mut RoomState, ev: &StoredRow) -> Result<(), BotError> {
    let plaintext = match decrypt_frame(device, &state.room, &ev.bytes) {
        Ok((sender, plaintext)) => {
            emit(&serde_json::json!({
                "event": "application", "room": state.room, "seq": ev.seq,
                "from": String::from_utf8_lossy(&sender), "bytes": plaintext.len(),
            }));
            plaintext
        }
        Err(_) => {
            // Undecryptable (wrong epoch, pre-join leftover): report and move
            // on — a single failure must not take the session down.
            emit(&serde_json::json!({
                "event": "undecryptable", "room": state.room, "seq": ev.seq, "bytes": ev.bytes.len(),
            }));
            return Ok(());
        }
    };
    match publish_echo(client, device, own, state, &plaintext) {
        Ok(()) => Ok(()),
        // Room moved under us (a commit we have not seen): resynchronize on the
        // next poll and replay once at the fresh epoch.
        Err(err @ BotError::Api { status: 409, .. }) => {
            state.retry = Some(plaintext);
            emit(&serde_json::json!({
                "event": "echo_conflict", "room": state.room, "seq": ev.seq,
                "error": err.to_string(),
            }));
            Ok(())
        }
        Err(err) => Err(report_dropped(state, &plaintext, err)),
    }
}

fn publish_echo(client: &Client, device: &mut Device, own: &str, state: &mut RoomState, plaintext: &[u8]) -> Result<(), BotError> {
    let framed = encrypt_frame(device, &state.room, own, plaintext)
        .map_err(|_| BotError::Local("encrypt echo"))?;
    // Relay-level dedup key, distinct per reply; the MLS AAD client_id inside
    // `framed` is the device identity (review H1), as the receivers require.
    let client_id = format!("{own}-echo-{}", state.echoes + 1);
    let post = EventPost {
        device: own,
        client_id: &client_id,
        kind: "application",
        epoch: state.epoch,
        revision: None,
        group_id: &state.room,
        targets: Vec::new(),
        members: Vec::new(),
        bytes: framed,
    };
    let resp = client.post_event(&state.room, &post)?;
    state.echoes += 1;
    // The echo's encryption advanced this device's own sender ratchet: the
    // new MLS state belongs on disk before the next poll.
    state.dirty = true;
    emit(&serde_json::json!({
        "event": "echo", "room": state.room, "bytes": plaintext.len(),
        "seq": resp.seq, "epoch": resp.epoch, "client_id": client_id,
    }));
    Ok(())
}

fn report_dropped(state: &RoomState, plaintext: &[u8], err: BotError) -> BotError {
    emit(&serde_json::json!({
        "event": "echo_dropped", "room": state.room, "bytes": plaintext.len(), "error": err.to_string(),
    }));
    err
}

// ---- framing (§3.6 u32 LE identity prefixes; DECRYPT_FORMAT 2) ----

fn push_identity(out: &mut Vec<u8>, part: &[u8]) {
    out.extend_from_slice(&(part.len() as u32).to_le_bytes());
    out.extend_from_slice(part);
}

fn read_identity(bytes: &[u8], at: &mut usize) -> Option<Vec<u8>> {
    let end = *at + 4;
    if bytes.len() < end { return None; }
    let len = u32::from_le_bytes(bytes[*at..end].try_into().ok()?) as usize;
    *at = end + len;
    if bytes.len() < *at { return None; }
    Some(bytes[end..*at].to_vec())
}

/// encrypt input: `u32 LE room_len ‖ room ‖ u32 LE client_len ‖ client ‖ plaintext`.
fn encrypt_frame(device: &mut Device, room: &str, client_id: &str, plaintext: &[u8]) -> Result<Vec<u8>, ()> {
    let mut input = Vec::with_capacity(8 + room.len() + client_id.len() + plaintext.len());
    push_identity(&mut input, room.as_bytes());
    push_identity(&mut input, client_id.as_bytes());
    input.extend_from_slice(plaintext);
    device.encrypt(&input).map_err(drop)
}

/// decrypt input: `u32 LE room_len ‖ room ‖ ciphertext`.
fn decrypt_frame(device: &mut Device, room: &str, ciphertext: &[u8]) -> Result<(Vec<u8>, Vec<u8>), ()> {
    let mut input = Vec::with_capacity(4 + room.len() + ciphertext.len());
    push_identity(&mut input, room.as_bytes());
    input.extend_from_slice(ciphertext);
    let out = device.decrypt(&input).map_err(drop)?;
    // DECRYPT_FORMAT 2: `u32 LE device_len ‖ device ‖ u32 LE client_id_len ‖
    // client_id ‖ plaintext`; the facade already enforced client_id == device.
    let mut at = 0;
    let sender = read_identity(&out, &mut at).ok_or(())?;
    let _client = read_identity(&out, &mut at).ok_or(())?;
    Ok((sender, out[at..].to_vec()))
}

// ---- output ----

fn emit(value: &serde_json::Value) {
    let mut out = std::io::stdout().lock();
    let _ = serde_json::to_writer(&mut out, value);
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}

fn status(rooms: &[RoomState]) {
    let rooms: Vec<_> = rooms
        .iter()
        .map(|state| {
            serde_json::json!({
                "room": state.room, "joined": state.joined, "echoes": state.echoes,
                "cursor": state.cursor, "epoch": state.epoch,
            })
        })
        .collect();
    emit(&serde_json::json!({ "event": "status", "rooms": rooms }));
}

fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes { out.push_str(&format!("{byte:02x}")); }
    out
}

/// Keep `b64` linked: the wire module owns it; this module reads none of its
/// output today. (The relay's base64-string bytes arrive decoded via serde.)
#[cfg(test)]
mod tests {
    use super::*;

    /// Framing helpers must round-trip the §3.6 shapes the facade parses.
    #[test]
    fn identity_frames_round_trip() {
        let mut input = Vec::new();
        push_identity(&mut input, b"family");
        push_identity(&mut input, b"bot-1");
        input.extend_from_slice(b"payload");
        let mut at = 0;
        assert_eq!(read_identity(&input, &mut at).unwrap(), b"family");
        assert_eq!(read_identity(&input, &mut at).unwrap(), b"bot-1");
        assert_eq!(&input[at..], b"payload");
        // Truncated lengths are rejected, not panics.
        assert_eq!(read_identity(&input[..6], &mut 0), None);
        assert_eq!(read_identity(&input[..9], &mut 0), None);
    }

    /// Scratch state file path, unique per test in this process.
    fn state_path(tag: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "bot-session-test-{}-{}.state", std::process::id(), tag,
        ))
    }

    /// persist → load must restore the same identity and the exact
    /// cursor/epoch/joined triple the envelope was written with.
    #[test]
    fn state_envelope_round_trips() {
        let path = state_path("roundtrip");
        let mut dev = Device::new("bot-1").unwrap_or_else(|_| panic!("device new"));
        let key_before = match dev.public_key() { Ok(key) => key, Err(_) => panic!("public key") };
        persist_state(&path, "family", "bot-1", &mut dev, 5, 3, true, 7).unwrap();
        let (mut restored, cursor, epoch, joined, echoes) =
            match load_state(Some(&path), "family", "bot-1") {
                Ok(Some(tuple)) => tuple,
                _ => panic!("state file must restore"),
            };
        // The echo counter rides along: the relay dedups by `<device>-echo-n`.
        assert_eq!((cursor, epoch, joined, echoes), (5, 3, true, 7));
        // Same identity: the public key that enrolled the bot survives.
        let key_after = match restored.public_key() { Ok(key) => key, Err(_) => panic!("public key") };
        assert_eq!(key_after, key_before);
        let _ = std::fs::remove_file(&path);
    }

    /// The envelope is bound to one room and one device: anything else must
    /// fail closed, never silently start a fresh device.
    #[test]
    fn state_rejects_foreign_room_device_and_version() {
        let path = state_path("binding");
        let mut dev = Device::new("bot-1").unwrap_or_else(|_| panic!("device new"));
        persist_state(&path, "family", "bot-1", &mut dev, 1, 1, false, 0).unwrap();
        for (room, device) in [("other", "bot-1"), ("family", "bot-2")] {
            assert!(
                matches!(
                    load_state(Some(&path), room, device),
                    Err(BotError::Local("state file is for another version/room/device")),
                ),
                "state for {room}/{device} must be rejected",
            );
        }
        // Wrong envelope version: a downgrade/upgrade on disk is a hard stop.
        let mut env: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        env["version"] = serde_json::json!(999);
        std::fs::write(&path, serde_json::to_vec(&env).unwrap()).unwrap();
        assert!(
            matches!(
                load_state(Some(&path), "family", "bot-1"),
                Err(BotError::Local("state file is for another version/room/device")),
            ),
            "wrong envelope version must be rejected",
        );
        let _ = std::fs::remove_file(&path);
    }

    /// Missing file → fresh device; corrupt file → session error, not a
    /// fresh start (fail-closed).
    #[test]
    fn state_missing_is_fresh_and_corrupt_fails() {
        let missing = state_path("missing");
        assert!(matches!(load_state(Some(&missing), "family", "bot-1"), Ok(None)));
        let path = state_path("corrupt");
        std::fs::write(&path, b"{not json").unwrap();
        assert!(
            matches!(
                load_state(Some(&path), "family", "bot-1"),
                Err(BotError::Local("state file corrupt")),
            ),
            "corrupt state must fail closed",
        );
        // Even valid JSON with the wrong shape (e.g. a truncated envelope)
        // must fail, not panic.
        std::fs::write(&path, br#"{"version":1}"#).unwrap();
        assert!(
            load_state(Some(&path), "family", "bot-1").is_err(),
            "truncated envelope must fail, not panic",
        );
        let _ = std::fs::remove_file(&path);
    }

    /// The snapshot is atomic (tmp + rename): a completed persist leaves the
    /// real file 0600 and no torn `.tmp` behind.
    #[cfg(unix)]
    #[test]
    fn persist_is_atomic_and_private() {
        use std::os::unix::fs::PermissionsExt;
        let path = state_path("atomic");
        let mut dev = Device::new("bot-1").unwrap_or_else(|_| panic!("device new"));
        persist_state(&path, "family", "bot-1", &mut dev, 2, 1, false, 0).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        let tmp = path.with_extension("state.tmp");
        assert!(!tmp.exists());
        let _ = std::fs::remove_file(&path);
    }
}
