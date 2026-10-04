//! M5 step 2 (#177 §7): the room session. `session <room> <device>
//! [<watch-room>]` publishes one key package, then long-polls the relay like
//! any other leaf:
//!
//! ```text
//! GET events?after=cursor&ack=acked → welcome (join) → commit (apply) →
//!   application (decrypt + echo-reply) → own events skipped
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
//! - A 409 `cas_mismatch` means the room moved under us: resynchronize on the
//!   next poll, then replay the dropped echo once at the fresh epoch. A 409
//!   `client_id_reuse` means an earlier incarnation already delivered that
//!   echo number: count it and move on (review 2 B-H2).
//! - Events before our Welcome are not ours to read. A Welcome delivered by the
//!   relay is always targeted at us (server-side filter); one that arrives
//!   after we joined, or in the watch room, is ignored — never joined, never
//!   fatal (B-H3).
//!
//! Review 2 (#231) hardening of the session loop:
//! - **Rollback guard (B-H1/B-H3)**: the facade retires a `Device` on any
//!   failed MLS operation ("never reuse uncertain state"). The bot therefore
//!   snapshots the device before every join/commit/decrypt and restores the
//!   snapshot when the operation is rejected, so one undecryptable or poison
//!   event is reported and skipped instead of silently killing the identity
//!   (and, with `--state-file`, persisting the dead state).
//! - **Persist before bytes leave (B-H2)**: an echo's ciphertext advances the
//!   sender ratchet; the new state and the echo counter reach the state file
//!   *before* the POST. A crash between persist and POST loses one echo; the
//!   old order (POST, then persist at the end of the round) could reuse a
//!   sender generation after a restart.
//! - **Ack (B-H4)**: once joined, every poll acknowledges the cursor that is
//!   on disk (or processed, without a state file) so the relay can prune.

use crate::api::{self, BotError, Client, EventPost, StoredRow};
use crate::policy;
use family_mls_browser_experiment::Device;
use std::collections::VecDeque;
use std::io::Write;
use std::path::Path;
use std::time::{Duration, Instant};
use zeroize::Zeroize;

/// Backstop so a stuck session can never hang CI: the harness normally
/// SIGTERMs the bot long before this. `NATIVE_MLS_BOT_MAX_SECS=0` disables
/// the deadline for a long-lived deployment (review 2 B-M9).
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
    path: Option<&Path>, room: &str, device: &str,
) -> Result<Option<(Device, i64, i64, bool, u64)>, BotError> {
    let Some(path) = path else { return Ok(None) };
    let mut raw = match std::fs::read(path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(BotError::Local("state file unreadable")),
    };
    let env: StateEnvelope =
        serde_json::from_slice(&raw).map_err(|_| BotError::Local("state file corrupt"))?;
    if env.version != STATE_VERSION || env.room != room || env.device != device {
        return Err(BotError::Local("state file is for another version/room/device"));
    }
    let mut state = serde_json::to_vec(&env.state).map_err(|_| BotError::Local("state file corrupt"))?;
    let imported = Device::import_state(device, &state);
    // Batch g: the file bytes and the re-serialized snapshot carried the whole
    // store; wipe both now that the Device owns the only live copy. (The
    // serde_json::Value inside `env` cannot be wiped — a known limit.)
    raw.zeroize();
    state.zeroize();
    let dev = imported.map_err(|_| BotError::Local("state import rejected"))?;
    Ok(Some((dev, env.cursor, env.epoch, env.joined, env.echoes)))
}

/// Atomic, durable write: the temp file is created 0600 from the start (no
/// umask window on the signing key — review 2 B-M1), fsynced, renamed over
/// the target, and the directory entry is fsynced so a power loss cannot
/// leave a zero-length state file for the restart to refuse.
fn persist_state(
    path: &Path, room: &str, device: &str, dev: &mut Device,
    cursor: i64, epoch: i64, joined: bool, echoes: u64,
) -> Result<(), BotError> {
    let mut bytes = dev.export_state(device).map_err(|_| BotError::Local("state export rejected"))?;
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
    let mut raw = serde_json::to_vec(&env).map_err(|_| BotError::Local("state envelope json"))?;
    bytes.zeroize();
    let written = write_state_file(path, &raw);
    raw.zeroize();
    written
}

/// The atomic write itself (split out so `persist_state` can wipe its buffers
/// on every exit path).
fn write_state_file(path: &Path, raw: &[u8]) -> Result<(), BotError> {
    let tmp = path.with_extension("state.tmp");
    let _ = std::fs::remove_file(&tmp);
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&tmp).map_err(|_| BotError::Local("state file create"))?;
    file.write_all(raw).map_err(|_| BotError::Local("state file write"))?;
    file.sync_all().map_err(|_| BotError::Local("state file fsync"))?;
    drop(file);
    std::fs::rename(&tmp, path).map_err(|_| BotError::Local("state file rename"))?;
    if let Some(dir) = path.parent() {
        let dir = if dir.as_os_str().is_empty() { Path::new(".") } else { dir };
        if let Ok(handle) = std::fs::File::open(dir) {
            let _ = handle.sync_all();
        }
    }
    Ok(())
}

struct RoomState {
    room: String,
    cursor: i64,
    epoch: i64,
    joined: bool,
    /// Only the main room is ever joined; the watch room (negative control)
    /// ignores Welcomes (B-H3).
    joinable: bool,
    /// Application messages decrypted and echoed back.
    echoes: u64,
    /// Set on 409 cas_mismatch: the next poll resynchronizes, then replays
    /// these plaintexts in order (review 2 L2: more than one slot). Each
    /// entry carries its attempt count: a replay is tried once per poll —
    /// the GET that applies the winning commit refreshes the epoch between
    /// attempts — and dropped (`echo_dropped`, non-fatal) after
    /// MAX_ECHO_ATTEMPTS, so a room that keeps moving cannot livelock the
    /// session (batch f: the drain used to loop inside one poll).
    retry: VecDeque<(Vec<u8>, u32)>,
    /// MLS state moved since the last state-file snapshot (join, commit,
    /// echo encrypt): the poll loop flushes it before the next round.
    dirty: bool,
    /// Cursor the relay may prune up to: what is on disk (with a state file)
    /// or processed (without one). Sent as `?ack=` once joined (B-H4).
    acked: i64,
    /// Last ack value the relay accepted; equal acks are not resent.
    ack_sent: i64,
    /// The relay refused our ack (removed from the room, or the room was
    /// reset): stop acking, keep reading.
    ack_disabled: bool,
    /// A foreign commit failed the policy check (#263): it was discarded, the
    /// device stays at its epoch and reads nothing further from this room.
    /// Durable through the refusal marker next to the state file, so a
    /// restart stays halted until the operator clears it (and re-adds the
    /// device — the discarded epoch cannot be re-staged on this lane).
    halted: bool,
}

/// Where the refusal marker lives: next to the state file.
fn refused_marker_path(state_file: &Path) -> std::path::PathBuf {
    let mut name = state_file.as_os_str().to_os_string();
    name.push(".refused");
    std::path::PathBuf::from(name)
}

/// Session-wide handles the per-event helpers need.
struct Ctx<'a> {
    client: &'a Client,
    own: &'a str,
    room: &'a str,
    state_file: Option<&'a Path>,
}

/// Flush the room's MLS state to disk (main room only — the watch room never
/// holds group state) and mark the cursor acknowledgeable.
fn flush(ctx: &Ctx, device: &mut Device, state: &mut RoomState) -> Result<(), BotError> {
    if let Some(path) = ctx.state_file {
        if state.room == ctx.room {
            persist_state(path, ctx.room, ctx.own, device, state.cursor, state.epoch, state.joined, state.echoes)?;
        }
    }
    state.dirty = false;
    state.acked = state.cursor;
    Ok(())
}

/// Run one MLS operation with rollback (review 2 B-H1/B-H3): the facade
/// retires the device on any rejected operation, so the pre-operation
/// snapshot is restored on failure and the caller reports and skips the
/// event. A snapshot that cannot be restored is a hard stop — the device is
/// already retired and nothing short of a re-enrollment helps.
fn guarded<T>(
    device: &mut Device, own: &str, op: impl FnOnce(&mut Device) -> Result<T, ()>,
) -> Result<Result<T, ()>, BotError> {
    let mut snapshot = device.export_state(own).map_err(|_| BotError::Local("state snapshot before operation"))?;
    let outcome = match op(device) {
        Ok(value) => Ok(Ok(value)),
        Err(()) => Device::import_state(own, &snapshot)
            .map(|restored| { *device = restored; Ok(Err(())) })
            .unwrap_or(Err(BotError::Local("state rollback after rejected operation"))),
    };
    snapshot.zeroize(); // batch g: the pre-operation store copy is not kept around
    outcome
}

pub fn run(opts: Options) -> Result<(), BotError> {
    let max_secs = std::env::var("NATIVE_MLS_BOT_MAX_SECS")
        .ok()
        .and_then(|raw| raw.parse().ok())
        .unwrap_or(DEFAULT_MAX_SECS);
    let deadline = if max_secs == 0 {
        None
    } else {
        Some(
            Instant::now()
                .checked_add(Duration::from_secs(max_secs))
                .ok_or(BotError::Local("NATIVE_MLS_BOT_MAX_SECS out of range"))?,
        )
    };
    let expired = |deadline: Option<Instant>| deadline.is_some_and(|d| Instant::now() >= d);
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
    let restored = restored_main.is_some();
    let restored_joined = restored_main.is_some_and(|(_, _, joined, _)| joined);
    // A resumed device that already sits in the group needs no key package:
    // minting one per restart would hit the facade's outstanding cap (8) and
    // the relay's live cap (4) after a handful of restarts (review 2 B-M2).
    let key_package = if restored_joined {
        None
    } else {
        match device.key_package() {
            Ok(kp) => Some(kp),
            Err(_) if restored => {
                emit(&serde_json::json!({
                    "event": "key_package_skipped", "device": opts.device, "room": opts.room,
                    "reason": "outstanding key packages at the facade cap; the relay's live package stays",
                }));
                None
            }
            Err(_) => return Err(BotError::Local("key package generation")),
        }
    };
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
        "restored": restored,
    }));
    // Persist before the key package's private material has a public
    // counterpart on the relay: a crash between publish and the first
    // snapshot must not leave a relay package no device can use. A fresh
    // device writes zeroes; a resumed-but-unjoined device that minted a new
    // package keeps its cursor/epoch and gains the package.
    if let (Some(path), Some(_)) = (opts.state_file.as_deref(), &key_package) {
        let (c, e, j, x) = restored_main.unwrap_or((0, 0, false, 0));
        persist_state(path, &opts.room, &opts.device, &mut device, c, e, j, x)?;
    }
    let mut auth_wait_announced = false;
    let key_ref = key_package.as_ref().map(|kp| api::ref_hex(kp));
    if let (Some(kp), Some(key_ref)) = (&key_package, &key_ref) {
        let stored = 'publish: loop {
            match client.post_key_packages(&opts.room, &opts.device, &[(key_ref, kp.clone())]) {
                Ok(stored) => break 'publish stored,
                // With -device-state on, every POST needs an active policy device:
                // the harness enrolls us from the `identity` line above, so the
                // first attempts may legitimately land before that. Retry. With
                // -access-mode required the identity line answers an *unknown*
                // device with the same opaque 403 device_subject_mismatch (the
                // relay refuses to reveal which of unknown/wrong-subject it was),
                // so pre-enrollment attempts surface under that code too.
                Err(BotError::Api { status: 403, code })
                    if code == "device_not_allowed" || code == "device_subject_mismatch" =>
                {
                    std::thread::sleep(POLL);
                    if expired(deadline) {
                        return Err(BotError::Local("session deadline exceeded waiting for enrollment"));
                    }
                }
                // A resumed device whose earlier package is still live on the
                // relay may run into the per-device live cap: that package
                // serves the invite, so this is not a failure.
                Err(BotError::Api { status: 409, code }) if restored && code == "key_package_limit" => {
                    emit(&serde_json::json!({
                        "event": "key_package_skipped", "device": opts.device, "room": opts.room,
                        "reason": "relay live cap reached; an earlier package of this device is still live",
                    }));
                    break 'publish 1;
                }
                // With -access-mode required, a short-lived assertion can lapse
                // while we wait for enrollment: wait for the token file to be
                // rotated (or to appear — review 2 B-M3) instead of dying.
                Err(BotError::Api { status: 401, .. } | BotError::Status { status: 401 } | BotError::AccessUnavailable(_)) => {
                    if !auth_wait_announced {
                        auth_wait_announced = true;
                        emit(&serde_json::json!({
                            "event": "auth_wait",
                            "room": opts.room,
                            "device": opts.device,
                        }));
                    }
                    std::thread::sleep(POLL);
                    if expired(deadline) {
                        return Err(BotError::Local("session deadline exceeded waiting for an access token"));
                    }
                }
                Err(err) => return Err(err),
            }
        };
        if stored != 1 {
            return Err(BotError::Local("relay stored an unexpected key package count"));
        }
    }
    emit(&serde_json::json!({
        "event": "ready",
        "device": opts.device,
        "room": opts.room,
        "watch_room": opts.watch_room,
        // Ed25519 public key hex: the harness enrolls the bot actor with it.
        "public_key": hex(&public_key),
        // null when a resumed, already-joined device published nothing.
        "key_ref": key_ref,
        "max_secs": max_secs,
        "restored": restored,
    }));

    let (c0, e0, j0, x0) = restored_main.unwrap_or((0, 0, false, 0));
    // #263: a refusal marker from an earlier run keeps the room halted — the
    // operator clears it deliberately (with a re-add), never a restart.
    let halted0 = opts.state_file.as_deref().map(refused_marker_path).filter(|p| p.exists());
    if let Some(marker) = &halted0 {
        // The marker's reason (a policy refusal code or `history_gap`, #268)
        // tells the operator which recovery applies; an unreadable marker
        // still halts.
        let reason = std::fs::read(marker)
            .ok()
            .and_then(|raw| serde_json::from_slice::<serde_json::Value>(&raw).ok())
            .and_then(|m| m.get("reason").cloned());
        emit(&serde_json::json!({
            "event": "halted", "room": opts.room, "device": opts.device,
            "marker": marker.display().to_string(), "reason": reason,
        }));
    }
    let mut rooms = vec![RoomState {
        room: opts.room.clone(), cursor: c0, epoch: e0, joined: j0, joinable: true, echoes: x0,
        retry: VecDeque::new(), dirty: false, acked: c0, ack_sent: 0, ack_disabled: false,
        halted: halted0.is_some(),
    }];
    if let Some(watch) = &opts.watch_room {
        // The negative control: a room the bot is never invited to. It must
        // stay unjoined and silent there for the whole session.
        rooms.push(RoomState {
            room: watch.clone(), cursor: 0, epoch: 0, joined: false, joinable: false, echoes: 0,
            retry: VecDeque::new(), dirty: false, acked: 0, ack_sent: 0, ack_disabled: true,
            halted: false,
        });
    }
    let ctx = Ctx { client: &client, own: &opts.device, room: &opts.room, state_file: opts.state_file.as_deref() };

    let mut rounds = 0u32;
    let mut auth_wait_announced = false;
    loop {
        if expired(deadline) {
            return Err(BotError::Local("session deadline exceeded"));
        }
        for state in &mut rooms {
            match poll_room(&ctx, &mut device, state) {
                Ok(()) => {}
                // 401 = the assertion expired or was rejected, or the token
                // file is momentarily empty/unreadable mid-rotation (B-M3).
                // The file may already carry a rotated token (or will soon):
                // keep polling until the deadline instead of dying, and say
                // why once so the harness can tell an auth wait from a hang.
                Err(BotError::Api { status: 401, .. } | BotError::Status { status: 401 } | BotError::AccessUnavailable(_)) => {
                    if !auth_wait_announced {
                        auth_wait_announced = true;
                        emit(&serde_json::json!({
                            "event": "auth_wait",
                            "room": state.room,
                            "device": opts.device,
                        }));
                    }
                }
                Err(err) => return Err(err),
            }
            // MLS state that moved this round goes to disk before the next
            // poll: a restart must resume from exactly this cursor or it
            // cannot decrypt (the group ratchets on). A persist failure takes
            // the session down — running on unpersisted state would fork the
            // identity silently. (Echo encrypts are flushed inside
            // publish_echo, before their ciphertext leaves the process.)
            if state.dirty {
                flush(&ctx, &mut device, state)?;
            }
        }
        rounds += 1;
        if rounds % STATUS_EVERY == 0 {
            status(&rooms);
        }
        std::thread::sleep(POLL);
    }
}

fn poll_room(ctx: &Ctx, device: &mut Device, state: &mut RoomState) -> Result<(), BotError> {
    // #263: a halted room is neither read nor acked — the device must not
    // move past the refused commit, and its cursor must keep gating pruning.
    if state.halted {
        return Ok(());
    }
    // Ack what is durably processed (B-H4). Only a joined member may ack
    // (the relay answers 403 not_a_member otherwise), and an ack the relay
    // refuses — bad_ack after a room reset, not_a_member after a removal —
    // disables acking rather than the session.
    let ack = (state.joined && !state.ack_disabled && state.acked > state.ack_sent).then_some(state.acked);
    let body = match ctx.client.get_events(&state.room, ctx.own, state.cursor, ack) {
        Ok(body) => body,
        // The watch room may not exist yet (its founding commit has not been
        // posted) — that is not an error, just nothing to see.
        Err(BotError::Api { status: 404, code }) if code == "no_such_room" => return Ok(()),
        Err(BotError::Api { status, code })
            if ack.is_some() && ((status == 400 && code == "bad_ack") || (status == 403 && code == "not_a_member")) =>
        {
            state.ack_disabled = true;
            emit(&serde_json::json!({
                "event": "ack_refused", "room": state.room, "ack": ack, "status": status, "error": code,
            }));
            return Ok(());
        }
        Err(err) => return Err(err),
    };
    if let Some(acked) = ack {
        state.ack_sent = acked;
    }
    // #268: the relay pruned seqs this joined device never read (its cursor
    // left the pruning gate — revoke, removal grace — or a commit outlived the
    // hard-max epoch window). Processing the page would skip the lost commits
    // and fail every later decrypt, or drop messages silently; instead the
    // room halts before anything in the page moves the cursor, so the signal
    // survives a restart and the operator re-adds the device (new Welcome).
    if let Some((from, to)) = history_gap(state.joined, state.cursor, body.first_seq) {
        return gap(ctx, state, body.first_seq, body.epoch, from, to);
    }
    state.epoch = body.epoch;
    for ev in &body.events {
        state.cursor = state.cursor.max(ev.seq);
        if ev.device == ctx.own {
            // Own echo. MLS never processes its own messages; when this bot
            // ever POSTs a commit, its echo is where merge_pending belongs.
            continue;
        }
        match ev.kind.as_str() {
            "welcome" if state.joinable && !state.joined => {
                match guarded(device, ctx.own, |d| d.join(&ev.bytes).map_err(drop))? {
                    Ok(()) => {
                        state.joined = true;
                        state.dirty = true;
                        emit(&serde_json::json!({
                            "event": "joined", "room": state.room, "epoch": ev.epoch, "seq": ev.seq,
                        }));
                    }
                    Err(()) => rejected(state, ev, "welcome"),
                }
            }
            // The relay filters welcomes to their targets, so one that reaches
            // a joined device (a re-invite) or the watch room is reported and
            // ignored — it is not ours to act on and must not be fatal.
            "welcome" => {
                state.dirty = true;
                emit(&serde_json::json!({
                    "event": "welcome_ignored", "room": state.room, "seq": ev.seq, "joined": state.joined,
                }));
            }
            // #263 two-step application (the human client's #261 rule, in
            // Rust): stage (authenticate + roster delta report), check the
            // delta against this device's roster and — when this commit is
            // the page's latest epoch — against the relay's enforced roster,
            // then merge. A facade rejection (poison commit) is rolled back and
            // reported as before; a policy refusal discards and halts the room.
            "commit" if state.joined => {
                match guarded(device, ctx.own, |d| d.stage_commit(&ev.bytes).map_err(drop))? {
                    Err(()) => rejected(state, ev, "commit"),
                    Ok(report) => {
                        let outer: Option<Vec<String>> = (ev.epoch + 1 == body.epoch)
                            .then(|| body.members.as_ref().map(|m| m.iter().map(|x| x.device.clone()).collect()))
                            .flatten();
                        let verdict = match (policy::parse_stage_report(&report),
                                             device.members().ok().and_then(|f| policy::parse_roster(&f))) {
                            (None, _) => Err(policy::Refusal { reason: "report_format", detail: format!("{} bytes", report.len()) }),
                            (_, None) => Err(policy::Refusal { reason: "roster_unavailable", detail: String::new() }),
                            (Some(parsed), Some(roster)) => {
                                let ids: Vec<String> = roster.into_iter().map(|m| m.id).collect();
                                policy::check_commit(&parsed, &ids, &ev.device, outer.as_deref()).map(|expected| (parsed, expected))
                            }
                        };
                        match verdict {
                            Ok((parsed, expected)) => {
                                match guarded(device, ctx.own, |d| d.merge_staged().map_err(drop))? {
                                    Ok(()) => {
                                        state.dirty = true;
                                        emit(&serde_json::json!({
                                            "event": "commit_applied", "room": state.room, "seq": ev.seq,
                                            "committer": ev.device, "epoch": ev.epoch + 1,
                                            "adds": parsed.adds.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
                                            "removes": parsed.removes.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
                                            "members": expected, "outer_checked": outer.is_some(),
                                        }));
                                    }
                                    Err(()) => rejected(state, ev, "commit"),
                                }
                            }
                            Err(refusal) => {
                                // Pure: drops the staged commit, keeps the epoch.
                                let _ = device.discard_staged();
                                refuse(ctx, state, ev, refusal)?;
                            }
                        }
                    }
                }
            }
            "application" if state.joined => echo(ctx, device, state, ev)?,
            // Everything before our Welcome (commits that formed the group,
            // other members' applications) is not ours to read.
            _ => {}
        }
    }
    if state.joined {
        // Replay only what was queued before this poll: an entry the relay
        // refuses again goes back on the queue for the *next* poll (whose
        // GET applies the commit that moved the epoch), never for this one.
        let due = std::mem::take(&mut state.retry);
        for (plaintext, attempts) in due {
            if attempts >= MAX_ECHO_ATTEMPTS {
                let err = BotError::Local("echo replay attempts exhausted");
                report_dropped(state, &plaintext, err);
                continue;
            }
            if let Err(err) = publish_echo(ctx, device, state, &plaintext, attempts) {
                return Err(report_dropped(state, &plaintext, err));
            }
        }
    }
    Ok(())
}

/// How many polls one echo may be replayed across after cas_mismatch before
/// it is dropped as `echo_dropped` (non-fatal).
const MAX_ECHO_ATTEMPTS: u32 = 8;

/// A poison event (undecryptable Welcome/commit): the device was rolled back,
/// the cursor moves past it and the state file records that.
fn rejected(state: &mut RoomState, ev: &StoredRow, kind: &str) {
    state.dirty = true;
    emit(&serde_json::json!({
        "event": "rejected", "room": state.room, "seq": ev.seq, "kind": kind, "bytes": ev.bytes.len(),
    }));
}

/// A commit this device refuses to merge (#263): loud, durable, and final for
/// this room. The marker next to the state file keeps a restart halted; the
/// operator clears it and re-adds the device (the discarded epoch cannot be
/// re-staged — the handshake step was consumed). Without a state file the
/// halt lives for this process only.
fn refuse(ctx: &Ctx, state: &mut RoomState, ev: &StoredRow, refusal: policy::Refusal) -> Result<(), BotError> {
    state.halted = true;
    state.dirty = true;
    emit(&serde_json::json!({
        "event": "commit_refused", "room": state.room, "seq": ev.seq, "committer": ev.device,
        "epoch": ev.epoch, "reason": refusal.reason, "detail": refusal.detail,
    }));
    write_halt_marker(ctx, state, &serde_json::json!({
        "room": state.room, "device": ctx.own, "seq": ev.seq, "committer": ev.device,
        "epoch": ev.epoch, "reason": refusal.reason, "detail": refusal.detail,
    }))
}

/// `Some((first missing seq, last missing seq))` when a joined device's
/// cursor lies below the relay's oldest retained seq minus one (#268). An
/// unjoined device has no history to lose — events before its Welcome are
/// not its to read — and `first_seq == 0` is an empty room or an older relay.
fn history_gap(joined: bool, cursor: i64, first_seq: i64) -> Option<(i64, i64)> {
    (joined && first_seq > 0 && first_seq > cursor.saturating_add(1)).then(|| (cursor + 1, first_seq - 1))
}

/// A pruned history gap (#268): loud, durable and final for this room, like
/// a refused commit — the same marker keeps a restart halted until the
/// operator clears it and re-adds the device. The cursor stays where it was:
/// nothing of the page was processed.
fn gap(ctx: &Ctx, state: &mut RoomState, first_seq: i64, relay_epoch: i64, from: i64, to: i64) -> Result<(), BotError> {
    state.halted = true;
    emit(&serde_json::json!({
        "event": "history_gap", "room": state.room, "after": state.cursor, "first_seq": first_seq,
        "missing_from": from, "missing_to": to, "epoch": state.epoch, "relay_epoch": relay_epoch,
    }));
    write_halt_marker(ctx, state, &serde_json::json!({
        "room": state.room, "device": ctx.own, "reason": "history_gap", "after": state.cursor,
        "first_seq": first_seq, "epoch": state.epoch, "relay_epoch": relay_epoch,
    }))
}

/// Main room only, and only with a state file: without one the halt lives
/// for this process.
fn write_halt_marker(ctx: &Ctx, state: &RoomState, marker: &serde_json::Value) -> Result<(), BotError> {
    if let (Some(path), true) = (ctx.state_file, state.room == ctx.room) {
        let raw = serde_json::to_vec_pretty(marker).map_err(|_| BotError::Local("halt marker json"))?;
        write_state_file(&refused_marker_path(path), &raw)?;
    }
    Ok(())
}

/// Decrypt one application event and reply with the identical plaintext.
fn echo(ctx: &Ctx, device: &mut Device, state: &mut RoomState, ev: &StoredRow) -> Result<(), BotError> {
    let plaintext = match guarded(device, ctx.own, |d| decrypt_frame(d, &state.room, &ev.bytes))? {
        Ok((sender, plaintext)) => {
            // Decrypting consumed receive keys: that state belongs on disk.
            state.dirty = true;
            emit(&serde_json::json!({
                "event": "application", "room": state.room, "seq": ev.seq,
                "from": String::from_utf8_lossy(&sender), "bytes": plaintext.len(),
                "client_id": ev.client_id,
            }));
            plaintext
        }
        Err(()) => {
            // Undecryptable (forged, wrong epoch, pre-join leftover): the
            // device was rolled back to its pre-decrypt state; report and
            // move on — a single failure must not take the session down.
            state.dirty = true;
            emit(&serde_json::json!({
                "event": "undecryptable", "room": state.room, "seq": ev.seq, "bytes": ev.bytes.len(),
            }));
            return Ok(());
        }
    };
    // Another bot's echo (relay client_id `<device>-echo-<n>`) is read but not
    // echoed back: two bots in one room would otherwise ping-pong until the
    // room cap (review 2 B-M5).
    if is_echo_client_id(&ev.client_id) {
        emit(&serde_json::json!({
            "event": "echo_skipped", "room": state.room, "seq": ev.seq, "client_id": ev.client_id,
        }));
        return Ok(());
    }
    match publish_echo(ctx, device, state, &plaintext, 0) {
        Ok(()) => Ok(()),
        Err(err) => Err(report_dropped(state, &plaintext, err)),
    }
}

/// `<something>-echo-<digits>`: the dedup key shape every bot echo carries.
fn is_echo_client_id(client_id: &str) -> bool {
    match client_id.rsplit_once("-echo-") {
        Some((prefix, digits)) => !prefix.is_empty() && !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()),
        None => false,
    }
}

fn publish_echo(ctx: &Ctx, device: &mut Device, state: &mut RoomState, plaintext: &[u8], attempts: u32) -> Result<(), BotError> {
    let framed = encrypt_frame(device, &state.room, ctx.own, plaintext)
        .map_err(|_| BotError::Local("encrypt echo"))?;
    // Relay-level dedup key, distinct per reply; the MLS AAD client_id inside
    // `framed` is the device identity (review H1), as the receivers require.
    state.echoes += 1;
    state.dirty = true;
    let client_id = format!("{}-echo-{}", ctx.own, state.echoes);
    // The encryption advanced this device's own sender ratchet and the
    // counter reserved a dedup key: both reach disk before the ciphertext
    // leaves the process (review 2 B-H2 — a restart must never re-derive a
    // sender generation that was already sent).
    flush(ctx, device, state)?;
    let post = EventPost {
        device: ctx.own,
        client_id: &client_id,
        kind: "application",
        epoch: state.epoch,
        revision: None,
        group_id: &state.room,
        targets: Vec::new(),
        members: Vec::new(),
        bytes: framed,
    };
    match ctx.client.post_event(&state.room, &post) {
        Ok(resp) => {
            emit(&serde_json::json!({
                "event": "echo", "room": state.room, "bytes": plaintext.len(),
                "seq": resp.seq, "epoch": resp.epoch, "client_id": client_id, "duplicate": resp.duplicate,
            }));
            Ok(())
        }
        // Room moved under us (a commit we have not seen): resynchronize on the
        // next poll and replay once at the fresh epoch.
        Err(err @ BotError::Api { status: 409, .. }) if api::error_code(&err) == Some("cas_mismatch") => {
            state.retry.push_back((plaintext.to_vec(), attempts + 1));
            emit(&serde_json::json!({
                "event": "echo_conflict", "room": state.room, "client_id": client_id,
                "attempt": attempts + 1, "error": err.to_string(),
            }));
            Ok(())
        }
        // An earlier incarnation of this identity already delivered this echo
        // number (state file restored from a backup, for instance): the relay
        // has the message, the counter is now past it — move on.
        Err(err @ BotError::Api { status: 409, .. }) if api::error_code(&err) == Some("client_id_reuse") => {
            emit(&serde_json::json!({
                "event": "echo_client_id_reuse", "room": state.room, "client_id": client_id,
                "error": err.to_string(),
            }));
            Ok(())
        }
        Err(err) => Err(err),
    }
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
    let end = at.checked_add(4)?;
    if bytes.len() < end { return None; }
    let len = u32::from_le_bytes(bytes[*at..end].try_into().ok()?) as usize;
    *at = end.checked_add(len)?;
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
                "cursor": state.cursor, "epoch": state.epoch, "acked": state.ack_sent,
                "halted": state.halted,
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

    /// Rollback guard (review 2 B-H1): a rejected operation must leave the
    /// device usable, not retired.
    #[test]
    fn guarded_rolls_back_a_rejected_operation() {
        let mut dev = Device::new("bot-1").unwrap_or_else(|_| panic!("device new"));
        // No group yet: decrypting garbage is rejected and would retire the
        // device without the guard.
        let outcome = guarded(&mut dev, "bot-1", |d| d.decrypt(b"garbage").map_err(drop).map(drop))
            .unwrap_or_else(|e| panic!("guard: {e}"));
        assert!(outcome.is_err(), "garbage must be rejected");
        // Still alive: a key package can be minted afterwards.
        assert!(dev.key_package().is_ok(), "device must not be retired after a guarded rejection");
    }

    /// Echo dedup keys of other bots are recognised so two bots never
    /// ping-pong (B-M5); ordinary client ids are not.
    #[test]
    fn echo_client_ids_are_recognised() {
        assert!(is_echo_client_id("bot-1-echo-3"));
        assert!(is_echo_client_id("x-echo-10"));
        assert!(!is_echo_client_id("a-1-7-text"));
        assert!(!is_echo_client_id("-echo-1"));
        assert!(!is_echo_client_id("bot-echo-"));
        assert!(!is_echo_client_id("bot-echo-x1"));
    }

    /// #268: only a joined device below `first_seq - 1` has lost history.
    #[test]
    fn history_gap_rule() {
        assert_eq!(history_gap(true, 4, 10), Some((5, 9)));
        assert_eq!(history_gap(true, 4, 6), Some((5, 5)));
        // Contiguous: the next seq is the oldest one held.
        assert_eq!(history_gap(true, 4, 5), None);
        assert_eq!(history_gap(true, 4, 1), None);
        // Empty room or a relay without the field.
        assert_eq!(history_gap(true, 4, 0), None);
        // Not joined: pre-Welcome history was never ours.
        assert_eq!(history_gap(false, 0, 10), None);
        assert_eq!(history_gap(true, i64::MAX, 10), None);
    }

    /// Canned relay: answers each accepted connection with the next body
    /// (HTTP 200) and records the request lines, then stops listening.
    fn canned_relay(bodies: Vec<String>) -> (String, std::thread::JoinHandle<Vec<String>>) {
        use std::io::{Read, Write as _};
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        let base = format!("http://127.0.0.1:{}", listener.local_addr().expect("addr").port());
        let handle = std::thread::spawn(move || {
            let mut seen = Vec::new();
            for body in bodies {
                let (mut stream, _) = listener.accept().expect("accept");
                let mut raw = Vec::new();
                let mut buf = [0u8; 1024];
                while !raw.windows(4).any(|w| w == b"\r\n\r\n") {
                    let n = stream.read(&mut buf).expect("read request");
                    assert!(n > 0, "eof before header terminator");
                    raw.extend_from_slice(&buf[..n]);
                }
                let text = String::from_utf8_lossy(&raw).to_string();
                seen.push(text.lines().next().unwrap_or_default().to_string());
                let resp = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}", body.len());
                stream.write_all(resp.as_bytes()).expect("write response");
            }
            seen
        });
        (base, handle)
    }

    fn joined_room(room: &str, cursor: i64) -> RoomState {
        RoomState {
            room: room.into(), cursor, epoch: 2, joined: true, joinable: true, echoes: 3,
            retry: VecDeque::new(), dirty: false, acked: cursor, ack_sent: cursor, ack_disabled: false,
            halted: false,
        }
    }

    /// #268 end to end through `poll_room`: a page whose `first_seq` lies past
    /// the cursor halts the room before any event moves the cursor, writes the
    /// durable marker with reason `history_gap`, and the next poll never
    /// touches the relay. A contiguous page (`first_seq == cursor + 1`) does
    /// not halt.
    #[test]
    fn poll_room_halts_on_history_gap() {
        let event = r#"{"seq":12,"device":"owner","client_id":"owner-1","kind":"application","epoch":5,"bytes":"Z2FyYmFnZQ==","sha256":"00","created_at":1}"#;
        let gap_page = format!(r#"{{"epoch":5,"revision":1,"events":[{event}],"first_seq":10}}"#);
        let ok_page = r#"{"epoch":2,"revision":1,"events":[],"first_seq":5}"#.to_string();
        let (base, server) = canned_relay(vec![ok_page, gap_page]);
        let client = Client::with_access(&base, api::Access::None);
        let path = state_path("gap");
        let marker = refused_marker_path(&path);
        let _ = std::fs::remove_file(&marker);
        let ctx = Ctx { client: &client, own: "bot-1", room: "family", state_file: Some(&path) };
        let mut dev = Device::new("bot-1").unwrap_or_else(|_| panic!("device new"));

        // Contiguous history: no halt.
        let mut contiguous = joined_room("family", 4);
        poll_room(&ctx, &mut dev, &mut contiguous).unwrap_or_else(|e| panic!("contiguous poll: {e}"));
        assert!(!contiguous.halted, "first_seq == cursor + 1 is contiguous");
        assert!(!marker.exists());

        // Pruned gap 5..=9: halt, cursor untouched, marker durable.
        let mut state = joined_room("family", 4);
        poll_room(&ctx, &mut dev, &mut state).unwrap_or_else(|e| panic!("gap poll: {e}"));
        assert!(state.halted, "a pruned gap must halt the room");
        assert_eq!(state.cursor, 4, "no event of the gap page may move the cursor");
        assert_eq!(state.epoch, 2, "the device epoch stays where it was");
        let written: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&marker).expect("marker written")).expect("marker json");
        assert_eq!(written["reason"], "history_gap");
        assert_eq!(written["after"], 4);
        assert_eq!(written["first_seq"], 10);

        // Halted: the next poll is a no-op (the canned relay has stopped
        // listening, so any request would fail).
        let seen = server.join().expect("server thread");
        poll_room(&ctx, &mut dev, &mut state).unwrap_or_else(|e| panic!("halted poll: {e}"));
        assert_eq!(seen.len(), 2);
        assert!(seen.iter().all(|line| line.starts_with("GET /v2/rooms/family/events?device=bot-1&after=4")), "{seen:?}");
        let _ = std::fs::remove_file(&marker);
    }

    /// Identity frames reject length overflow instead of panicking (L1-style
    /// arithmetic on untrusted lengths).
    #[test]
    fn read_identity_rejects_overflowing_length() {
        let mut input = Vec::new();
        input.extend_from_slice(&u32::MAX.to_le_bytes());
        input.extend_from_slice(b"xx");
        assert_eq!(read_identity(&input, &mut 0), None);
        assert_eq!(read_identity(&input, &mut usize::MAX), None);
    }
}
