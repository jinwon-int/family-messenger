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
// #366 2a: the host-neutral room rules live in host-core; the bot keeps logging,
// halt markers and its state file.
use native_mls_host::room::{self, is_transient, relay_backoff, Halt, RoomSync, SendOutcome, SyncEvent};
#[cfg(test)]
use native_mls_host::room::history_gap;
#[cfg(test)]
use native_mls_host::room::RELAY_BACKOFF_MAX;
use crate::responder::{self, Inbound, Outbound, Responder};
use family_mls_browser_experiment::Device;
use std::collections::VecDeque;
use std::io::Write;
use std::path::{Path, PathBuf};
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
    /// Agent mode (#354 A1): when set, application messages are offered to the
    /// stdio worker instead of being echoed. `None` = the original echo bot.
    pub responder: Option<responder::Config>,
}

/// What this device does with a room's application messages (#372 P2).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    /// Legacy single-room bot without a responder: reply with the plaintext.
    Echo,
    /// Offer every message to the responder worker (#354 ②-B).
    Agent,
    /// Decrypt (the ratchet must advance) and log, answer nothing — the
    /// steward's default for rooms it founds (#372 D3).
    Silent,
    /// Negative control: never joined, never answered (B-H3).
    Watch,
    /// #423: the fleet alert room — the responder's `notice` frames are
    /// posted here, room messages never become turns (decrypted and logged
    /// like `Silent`; bot-to-bot rules are #425's).
    Alert,
}

impl Mode {
    pub fn parse(s: &str) -> Option<Mode> {
        match s.trim() { "agent" => Some(Mode::Agent), "silent" => Some(Mode::Silent), "alert" => Some(Mode::Alert), _ => None }
    }
    fn name(self) -> &'static str {
        match self { Mode::Echo => "echo", Mode::Agent => "agent", Mode::Silent => "silent", Mode::Watch => "watch", Mode::Alert => "alert" }
    }
}

/// A commit this device POSTed and has not yet seen echoed back (#372 P2):
/// the own echo is where `merge_pending` happens; an invite then sends its
/// Welcome to `targets` at the new epoch.
struct PendingCommit {
    seq: i64,
    welcome: Option<Vec<u8>>,
    targets: Vec<String>,
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
    /// The host-neutral sync position (#366 2b): room · cursor · epoch ·
    /// joined · joinable · dirty · acked · ack_sent · ack_disabled · halted —
    /// read through `Deref` as `state.cursor` etc.
    sync: RoomSync,
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
    /// This room's MLS device (#372 P2: one `Device` = one group, so a
    /// multi-room bot holds one per room, all sharing the identity's signer).
    device: Device,
    /// Where this room's state is persisted; `None` = memory only (the watch
    /// room, or a bot run without `--state-file`).
    state_path: Option<PathBuf>,
    mode: Mode,
    pending: Option<PendingCommit>,
}

impl std::ops::Deref for RoomState {
    type Target = RoomSync;
    fn deref(&self) -> &RoomSync { &self.sync }
}

impl std::ops::DerefMut for RoomState {
    fn deref_mut(&mut self) -> &mut RoomSync { &mut self.sync }
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
}

/// Flush the room's MLS state to disk (rooms with a state path — the watch
/// room never holds group state) and mark the cursor acknowledgeable.
fn flush(ctx: &Ctx, state: &mut RoomState) -> Result<(), BotError> {
    if let Some(path) = state.state_path.clone() {
        let RoomState { sync, device, echoes, .. } = state;
        persist_state(&path, &sync.room, ctx.own, device, sync.cursor, sync.epoch, sync.joined, *echoes)?;
    }
    state.dirty = false;
    state.acked = state.cursor;
    Ok(())
}

/// The facade `Device` seen through host-core's [`room::MlsGroup`] (#366 2a).
/// Borrowed per call, so `RoomState` keeps holding a plain `Device`; `own` is
/// the identity its state export/import is bound to.
struct Bound<'a> {
    dev: &'a mut Device,
    own: &'a str,
    /// The room id the facade framing binds a decrypt to; `None` for the
    /// operations that never decrypt (`guarded` around join/commit/invite).
    room: Option<&'a str>,
}

impl room::MlsGroup for Bound<'_> {
    /// batch g: the pre-operation store copy is wiped when the guard drops it.
    type Snapshot = zeroize::Zeroizing<Vec<u8>>;
    fn snapshot(&self) -> Result<Self::Snapshot, ()> {
        self.dev.export_state(self.own).map(zeroize::Zeroizing::new).map_err(drop)
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
        decrypt_frame(self.dev, self.room.ok_or(())?, ciphertext)
    }
    /// AAD client_id = the device identity (review H1); the relay's dedup key
    /// (`<device>-echo-<n>`) is a separate POST field.
    fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, ()> {
        encrypt_frame(self.dev, self.room.ok_or(())?, self.own, plaintext)
    }
}

/// Run one MLS operation with rollback (review 2 B-H1/B-H3) — host-core's
/// [`room::guarded`] over the bot's `Device`.
fn guarded<T>(
    device: &mut Device, own: &str, op: impl FnOnce(&mut Device) -> Result<T, ()>,
) -> Result<Result<T, ()>, BotError> {
    room::guarded(&mut Bound { dev: device, own, room: None }, |b| op(b.dev))
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
    // Agent mode: spawn the worker now (after `ready`, before the first poll).
    // A spawn failure is fatal — running as a silent echo-less bot would hide it.
    let mut agent: Option<Responder> = match &opts.responder {
        Some(config) => {
            let responder = Responder::spawn(config.clone(), opts.state_file.as_deref())?;
            emit(&serde_json::json!({
                "event": "agent_started", "room": opts.room, "device": opts.device,
                "owner_actor": config.owner_actor, "queue_max": config.queue_max,
                "turn_secs": config.turn_secs, "reply_max_bytes": config.reply_max_bytes,
            }));
            Some(responder)
        }
        None => None,
    };

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
        sync: RoomSync { room: opts.room.clone(), cursor: c0, epoch: e0, joined: j0, joinable: true, dirty: false, acked: c0, ack_sent: 0, ack_disabled: false, halted: halted0.is_some() },
        echoes: x0, retry: VecDeque::new(), device, state_path: opts.state_file.clone(), mode: if agent.is_some() { Mode::Agent } else { Mode::Echo }, pending: None,
    }];
    if let Some(watch) = &opts.watch_room {
        // The negative control: a room the bot is never invited to. It must
        // stay unjoined and silent there for the whole session.
        rooms.push(RoomState {
            sync: RoomSync { room: watch.clone(), cursor: 0, epoch: 0, joined: false, joinable: false, dirty: false, acked: 0, ack_sent: 0, ack_disabled: true, halted: false },
            echoes: 0, retry: VecDeque::new(), device: Device::new(&opts.device).map_err(|_| BotError::Local("device new: identity shape rejected"))?, state_path: None, mode: Mode::Watch, pending: None,
        });
    }
    let ctx = Ctx { client: &client, own: &opts.device };
    run_loop(&ctx, &mut rooms, &mut agent, deadline, None)
}

/// The polling loop shared by the single-room session and the steward
/// (#372 P2): poll every room, flush what moved, serve the command queue
/// (steward only), route the responder's output to the agent room.
fn run_loop(
    ctx: &Ctx, rooms: &mut Vec<RoomState>, agent: &mut Option<Responder>, deadline: Option<Instant>,
    steward: Option<&Steward>,
) -> Result<(), BotError> {
    let expired = |deadline: Option<Instant>| deadline.is_some_and(|d| Instant::now() >= d);

    let mut rounds = 0u32;
    let mut auth_wait_announced = false;
    // #392: consecutive rounds that could not reach the relay.
    let mut unreachable = 0u32;
    loop {
        if expired(deadline) {
            return Err(BotError::Local("session deadline exceeded"));
        }
        let mut round_unreachable: Option<String> = None;
        for state in rooms.iter_mut() {
            let before = (state.cursor, state.epoch, state.dirty);
            match poll_room(ctx, state, agent) {
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
                            "device": ctx.own,
                        }));
                    }
                }
                // #392: the relay is restarting or briefly unreachable, and
                // nothing of this room moved (the page read itself failed).
                // Waiting it out keeps the session — and an agent turn in
                // flight — alive. A failure after the room moved (a Welcome
                // or echo POST mid-page) still ends the session: the restart
                // resumes from the persisted cursor and replays that step.
                Err(err) if is_transient(&err) && (state.cursor, state.epoch, state.dirty) == before => {
                    round_unreachable = Some(err.to_string());
                    break;
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
                flush(ctx, state)?;
            }
        }
        if let Some(error) = round_unreachable {
            unreachable += 1;
            let mut wait = relay_backoff(unreachable);
            if let Some(d) = deadline {
                wait = wait.min(d.saturating_duration_since(Instant::now()));
            }
            emit(&serde_json::json!({
                "event": "relay_unreachable", "device": ctx.own, "attempt": unreachable,
                "wait_ms": wait.as_millis() as u64, "error": error,
            }));
            std::thread::sleep(wait);
            continue;
        }
        if unreachable > 0 {
            emit(&serde_json::json!({ "event": "relay_reachable", "device": ctx.own, "after_attempts": unreachable }));
            unreachable = 0;
        }
        // Steward (#372 P2): one queued operator command per round.
        if let Some(steward) = steward {
            steward.serve_one(ctx, rooms)?;
        }
        // Agent mode: worker output → the agent room (encrypted and posted like
        // an echo). Only one room carries agent text (legacy: rooms[0]; steward:
        // the room in `agent` mode); the others stay silent (B-H3). A dead
        // worker ends the session: the service manager restarts both halves
        // together rather than leaving a bot that reads everything and answers
        // nothing.
        if let Some(responder) = agent.as_mut() {
            let multi = responder.room_frames();
            for (item_room, item) in responder.pump_routed()? {
                // P4: a tool call runs through the steward and answers on the
                // port; it never reaches the room. Owner-only was enforced by
                // the responder before it emitted the item.
                if let Outbound::ToolCall { tool_id, name, op, room, arg } = &item {
                    let outcome = match steward {
                        None => Err("steward_only".to_string()),
                        Some(steward) => {
                            let cmd = Command { op: op.clone(), room: room.clone(), arg: arg.clone() };
                            match steward.execute(ctx, rooms, &cmd) {
                                Ok(mut value) => { value["ok"] = serde_json::Value::Bool(true); Ok(value) }
                                Err(err) => Err(err.to_string()),
                            }
                        }
                    };
                    let mut event = serde_json::json!({
                        "event": "agent_tool", "name": name, "op": op, "room": room, "arg": arg, "ok": outcome.is_ok(),
                    });
                    // #380 P5: which pool the invite's key package came from (room | lobby).
                    if let Some(source) = outcome.as_ref().ok().and_then(|v| v.get("key_source")) {
                        event["key_source"] = source.clone();
                    }
                    emit(&event);
                    responder.tool_result(tool_id, outcome);
                    continue;
                }
                // #423: the item goes to its turn's room (or a notice's own
                // room); `""` and the single-room wire keep the one agent room.
                let Some(main) = target_room(rooms, multi, &item_room, &item) else {
                    emit(&serde_json::json!({ "event": "agent_outbound_dropped", "room": item_room, "reason": "no_agent_room" }));
                    continue;
                };
                match &item {
                    Outbound::WorkerGone { reason } => {
                        emit(&serde_json::json!({ "event": "agent_worker_gone", "room": main.room, "reason": reason }));
                        return Err(BotError::Local("responder worker gone"));
                    }
                    Outbound::ToolCall { .. } => {
                        // Handled above; never text for the room.
                        emit(&serde_json::json!({ "event": "agent_outbound_dropped", "room": main.room, "reason": "tool_call" }));
                    }
                    Outbound::Notice { room, .. } if *room != main.room => {
                        // #474: only an agent room (#423: or the alert room)
                        // carries agent text (B-H3); a notice addressed
                        // anywhere else stays unsaid.
                        emit(&serde_json::json!({ "event": "agent_outbound_dropped", "room": room, "reason": "notice_not_agent_room" }));
                    }
                    _ => {
                        let text = agent_text(&item);
                        emit(&serde_json::json!({
                            "event": "agent_outbound", "room": main.room, "kind": agent_kind(&item), "bytes": text.len(),
                        }));
                        if !main.joined || main.halted {
                            emit(&serde_json::json!({ "event": "agent_outbound_dropped", "room": main.room, "reason": "not_joined_or_halted" }));
                            continue;
                        }
                        if let Err(err) = publish_echo(ctx, main, text.as_bytes(), 0) {
                            return Err(report_dropped(main, text.as_bytes(), err));
                        }
                    }
                }
            }
        }
        rounds += 1;
        if rounds % STATUS_EVERY == 0 {
            status(rooms);
        }
        std::thread::sleep(POLL);
    }
}

/// #423: the room one responder item is posted to.
///
/// Single-room wire (`multi` off): always the one agent room — exactly the
/// #354/#474 behaviour (a notice for another room is then dropped by the
/// caller). With room frames: a notice goes to its own room when that room
/// is in `agent` or `alert` mode; a turn's item goes to the turn's room while
/// it is still in `agent` mode (switched to silent mid-turn = unsaid); an item
/// with no room (`WorkerGone`, inbox from before #423) to the first agent room.
fn target_room<'r>(rooms: &'r mut [RoomState], multi: bool, item_room: &str, item: &Outbound) -> Option<&'r mut RoomState> {
    if !multi || item_room.is_empty() {
        return rooms.iter_mut().find(|r| r.mode == Mode::Agent);
    }
    let notice = matches!(item, Outbound::Notice { .. });
    rooms.iter_mut().find(|r| r.room == item_room && (r.mode == Mode::Agent || (notice && r.mode == Mode::Alert)))
}

/// Room text for one worker item (Korean, plain — the family reads this).
fn agent_text(item: &Outbound) -> String {
    match item {
        Outbound::Reply { text, .. } => text.clone(),
        Outbound::Interim { text, .. } => text.clone(),
        Outbound::Notice { text, .. } => text.clone(),
        Outbound::ApprovalRequest { text, .. } => text.clone(),
        Outbound::ApprovalResolved { n, allowed } => {
            if *allowed { format!("승인 #{n}: 허용했습니다.") } else { format!("승인 #{n}: 거절했습니다.") }
        }
        Outbound::Uncertain { seq, reason } => {
            format!("⚠️ 요청(#{seq})을 끝까지 확인하지 못했습니다({reason}). 다시 말씀해 주세요 — 같은 요청을 자동으로 다시 실행하지는 않습니다.")
        }
        Outbound::WorkerGone { reason } => format!("⚠️ 응답기가 멈췄습니다({reason})."),
        // Never posted (P4): the poll loop answers it on the port.
        Outbound::ToolCall { .. } => String::new(),
    }
}

fn agent_kind(item: &Outbound) -> &'static str {
    match item {
        Outbound::Reply { .. } => "reply",
        Outbound::Interim { .. } => "interim",
        Outbound::Notice { .. } => "notice",
        Outbound::ApprovalRequest { .. } => "approval_request",
        Outbound::ApprovalResolved { .. } => "approval_resolved",
        Outbound::Uncertain { .. } => "uncertain",
        Outbound::WorkerGone { .. } => "worker_gone",
        Outbound::ToolCall { .. } => "tool_call",
    }
}

fn poll_room(ctx: &Ctx, state: &mut RoomState, agent: &mut Option<Responder>) -> Result<(), BotError> {
    // #366 2b: the sync state machine (ack · GET · gap · welcome/commit/
    // application in page order) is host-core's `room::poll`; `BotRoom` is the
    // bot's side of it — logging, halt markers, echo/agent/silent, own commits
    // and the echo replay queue.
    room::poll(&mut BotRoom { ctx, state, agent }, ctx.own)
}

/// One room of this bot as a `room::RoomHost` (#366 2b).
struct BotRoom<'s, 'c> {
    ctx: &'s Ctx<'c>,
    state: &'s mut RoomState,
    agent: &'s mut Option<Responder>,
}

impl room::RoomAccess for BotRoom<'_, '_> {
    type Group<'g> = Bound<'g> where Self: 'g;
    fn sync(&mut self) -> &mut RoomSync { &mut self.state.sync }
    fn group(&mut self) -> Bound<'_> { bound(self.ctx, self.state) }
}

/// The room's `Device` lent to host-core for one operation, framing bound to the room.
fn bound<'a>(ctx: &'a Ctx, state: &'a mut RoomState) -> Bound<'a> {
    let state = &mut *state;
    Bound { dev: &mut state.device, own: ctx.own, room: Some(&state.sync.room) }
}

impl room::RoomHost for BotRoom<'_, '_> {
    fn fetch(&mut self, room: &str, after: i64, ack: Option<i64>) -> Result<api::EventsResponse, BotError> {
        self.ctx.client.get_events(room, self.ctx.own, after, ack)
    }

    fn report(&mut self, event: SyncEvent<'_>) {
        let room = &self.state.room;
        emit(&match event {
            SyncEvent::AckRefused { ack, status, code } => serde_json::json!({
                "event": "ack_refused", "room": room, "ack": ack, "status": status, "error": code,
            }),
            SyncEvent::Joined { epoch, seq } => serde_json::json!({
                "event": "joined", "room": room, "epoch": epoch, "seq": seq,
            }),
            SyncEvent::WelcomeIgnored { seq, joined } => serde_json::json!({
                "event": "welcome_ignored", "room": room, "seq": seq, "joined": joined,
            }),
            // A poison event (undecryptable Welcome/commit): the device was
            // rolled back, the cursor moves past it and the state file records that.
            SyncEvent::Rejected { seq, kind, bytes } => serde_json::json!({
                "event": "rejected", "room": room, "seq": seq, "kind": kind, "bytes": bytes,
            }),
            SyncEvent::CommitApplied { ev, report, members, outer_checked } => serde_json::json!({
                "event": "commit_applied", "room": room, "seq": ev.seq,
                "committer": ev.device, "epoch": ev.epoch + 1,
                "adds": report.adds.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
                "removes": report.removes.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
                "members": members, "outer_checked": outer_checked,
            }),
            SyncEvent::Application { ev, sender, bytes } => serde_json::json!({
                "event": "application", "room": room, "seq": ev.seq,
                "from": String::from_utf8_lossy(sender), "bytes": bytes,
                "client_id": ev.client_id,
            }),
            // Undecryptable (forged, wrong epoch, pre-join leftover): the
            // device was rolled back to its pre-decrypt state; reported and
            // skipped — a single failure must not take the session down.
            SyncEvent::Undecryptable { seq, bytes } => serde_json::json!({
                "event": "undecryptable", "room": room, "seq": seq, "bytes": bytes,
            }),
        });
    }

    fn halt(&mut self, halt: Halt<'_>) -> Result<(), BotError> {
        match halt {
            Halt::Refused { ev, refusal } => refuse(self.ctx, self.state, ev, refusal),
            Halt::Gap { first_seq, relay_epoch, from, to } => gap(self.ctx, self.state, first_seq, relay_epoch, from, to),
        }
    }

    fn application(&mut self, ev: &StoredRow, sender: Vec<u8>, plaintext: Vec<u8>) -> Result<(), BotError> {
        echo(self.ctx, self.state, ev, &sender, &plaintext, self.agent)
    }

    /// Own echo. MLS never processes its own messages; a commit this device
    /// POSTed (#372 P2 invite/remove) merges here, and an invite then sends its
    /// Welcome at the new epoch.
    fn own_event(&mut self, ev: &StoredRow) -> Result<(), BotError> {
        if ev.kind == "commit" {
            if let Some(pending) = self.state.pending.take() {
                own_commit_echo(self.ctx, self.state, ev, pending)?;
            }
        }
        Ok(())
    }

    /// Replay only what was queued before this poll: an entry the relay
    /// refuses again goes back on the queue for the *next* poll (whose GET
    /// applies the commit that moved the epoch), never for this one.
    fn after_page(&mut self) -> Result<(), BotError> {
        let state = &mut *self.state;
        let due = std::mem::take(&mut state.retry);
        for (plaintext, attempts) in due {
            if attempts >= MAX_ECHO_ATTEMPTS {
                let err = BotError::Local("echo replay attempts exhausted");
                report_dropped(state, &plaintext, err);
                continue;
            }
            if let Err(err) = publish_echo(self.ctx, state, &plaintext, attempts) {
                return Err(report_dropped(state, &plaintext, err));
            }
        }
        Ok(())
    }
}

/// How many polls one echo may be replayed across after cas_mismatch before
/// it is dropped as `echo_dropped` (non-fatal).
const MAX_ECHO_ATTEMPTS: u32 = 8;

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

/// Only rooms with a state path: without one the halt lives for this process.
fn write_halt_marker(_ctx: &Ctx, state: &RoomState, marker: &serde_json::Value) -> Result<(), BotError> {
    if let Some(path) = &state.state_path {
        let raw = serde_json::to_vec_pretty(marker).map_err(|_| BotError::Local("halt marker json"))?;
        write_state_file(&refused_marker_path(path), &raw)?;
    }
    Ok(())
}

/// What this room does with one decrypted application message (#366 2b:
/// `room::poll` decrypted it and logged `application`): skip another bot's
/// echo, offer it to the agent, stay silent, or reply with the identical plaintext.
fn echo(ctx: &Ctx, state: &mut RoomState, ev: &StoredRow, sender: &[u8], plaintext: &[u8], agent: &mut Option<Responder>) -> Result<(), BotError> {
    // Another bot's echo (relay client_id `<device>-echo-<n>`) is read but not
    // echoed back: two bots in one room would otherwise ping-pong until the
    // room cap (review 2 B-M5).
    if is_echo_client_id(&ev.client_id) {
        emit(&serde_json::json!({
            "event": "echo_skipped", "room": state.room, "seq": ev.seq, "client_id": ev.client_id,
        }));
        return Ok(());
    }
    // Agent mode (#354): the agent room's messages go to the worker; the watch
    // room (never joined) cannot reach here. Nothing is echoed in this mode.
    // A silent room (#372 D3) decrypts — the ratchet must advance — and stops.
    match state.mode {
        Mode::Agent => match agent.as_mut() {
            Some(responder) => route_to_agent(state, ev, sender, plaintext, responder),
            None => {
                emit(&serde_json::json!({ "event": "agent_skipped", "room": state.room, "seq": ev.seq, "reason": "no_responder" }));
                Ok(())
            }
        },
        Mode::Silent | Mode::Watch | Mode::Alert => Ok(()),
        Mode::Echo => match publish_echo(ctx, state, plaintext, 0) {
            Ok(()) => Ok(()),
            Err(err) => Err(report_dropped(state, plaintext, err)),
        },
    }
}

/// Agent mode: decide whether one decrypted message becomes a turn, an
/// approval reply, or nothing (②-B all messages; ③-B all non-bot actors;
/// ④-B owner-only approval replies). Pure routing — no MLS here.
fn route_to_agent(state: &mut RoomState, ev: &StoredRow, sender: &[u8], plaintext: &[u8], agent: &mut Responder) -> Result<(), BotError> {
    let sender_device = String::from_utf8_lossy(sender).into_owned();
    let skipped = |reason: &str| {
        emit(&serde_json::json!({
            "event": "agent_skipped", "room": state.room, "seq": ev.seq, "from": sender_device, "reason": reason,
        }));
    };
    if responder::is_bot_actor(&sender_device) {
        skipped("bot_actor");
        return Ok(());
    }
    if responder::is_attachment_client_id(&ev.client_id) {
        skipped("attachment");
        return Ok(());
    }
    let text = match std::str::from_utf8(plaintext) {
        Ok(text) if !text.trim().is_empty() => text.to_string(),
        _ => {
            skipped("non_utf8_or_empty");
            return Ok(());
        }
    };
    if responder::actor_of(&sender_device) == agent.owner_actor() {
        if let Some((n, allow)) = responder::parse_approval_reply(&text) {
            let known = agent.resolve(n, allow).is_some();
            emit(&serde_json::json!({
                "event": "agent_approval_reply", "room": state.room, "seq": ev.seq, "n": n, "allow": allow, "known": known,
            }));
            return Ok(());
        }
    }
    let offer = agent.offer(Inbound { room: state.room.clone(), seq: ev.seq, sender_device: sender_device.clone(), text })?;
    emit(&serde_json::json!({
        "event": "agent_offer", "room": state.room, "seq": ev.seq, "from": sender_device, "outcome": format!("{offer:?}"),
    }));
    Ok(())
}

/// `<something>-echo-<digits>`: the dedup key shape every bot echo carries.
fn is_echo_client_id(client_id: &str) -> bool {
    match client_id.rsplit_once("-echo-") {
        Some((prefix, digits)) => !prefix.is_empty() && !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()),
        None => false,
    }
}

/// One room of this bot as a `room::SendHost` (#366 2c): the dedup key is
/// `<device>-echo-<n>` from the persisted counter, `persist` is the state-file
/// flush, `post` is the relay client.
struct BotSender<'s, 'c> {
    ctx: &'s Ctx<'c>,
    state: &'s mut RoomState,
}

impl room::RoomAccess for BotSender<'_, '_> {
    type Group<'g> = Bound<'g> where Self: 'g;
    fn sync(&mut self) -> &mut RoomSync { &mut self.state.sync }
    fn group(&mut self) -> Bound<'_> { bound(self.ctx, self.state) }
}

impl room::SendHost for BotSender<'_, '_> {
    fn reserve_client_id(&mut self) -> String {
        self.state.echoes += 1;
        format!("{}-echo-{}", self.ctx.own, self.state.echoes)
    }
    fn persist(&mut self) -> Result<(), BotError> { flush(self.ctx, self.state) }
    fn post(&mut self, room: &str, post: &EventPost<'_>) -> Result<api::EventResponse, BotError> {
        self.ctx.client.post_event(room, post)
    }
}

/// Encrypt and POST one reply (host-core `room::send_application`, #366 2c):
/// the ratchet step and the echo counter reach disk before the ciphertext
/// leaves (review 2 B-H2). A 409 cas_mismatch queues the plaintext for the
/// next poll (replayed once at the fresh epoch); a 409 client_id_reuse means an
/// earlier incarnation already delivered it.
fn publish_echo(ctx: &Ctx, state: &mut RoomState, plaintext: &[u8], attempts: u32) -> Result<(), BotError> {
    let outcome = room::send_application(&mut BotSender { ctx, state }, ctx.own, plaintext)?;
    match outcome {
        SendOutcome::Sent { client_id, response } => emit(&serde_json::json!({
            "event": "echo", "room": state.room, "bytes": plaintext.len(),
            "seq": response.seq, "epoch": response.epoch, "client_id": client_id, "duplicate": response.duplicate,
        })),
        SendOutcome::Conflict { client_id, error } => {
            state.retry.push_back((plaintext.to_vec(), attempts + 1));
            emit(&serde_json::json!({
                "event": "echo_conflict", "room": state.room, "client_id": client_id,
                "attempt": attempts + 1, "error": error.to_string(),
            }));
        }
        SendOutcome::AlreadyDelivered { client_id, error } => emit(&serde_json::json!({
            "event": "echo_client_id_reuse", "room": state.room, "client_id": client_id,
            "error": error.to_string(),
        })),
    }
    Ok(())
}

fn report_dropped(state: &RoomState, plaintext: &[u8], err: BotError) -> BotError {
    emit(&serde_json::json!({
        "event": "echo_dropped", "room": state.room, "bytes": plaintext.len(), "error": err.to_string(),
    }));
    err
}


// ---- #372 P2: own commits, identity file, steward (multi-room + command queue) ----

/// The relay echoed a commit this device POSTed: merge it, move the epoch,
/// and (for an invite) send the Welcome to its targets at the new epoch.
fn own_commit_echo(ctx: &Ctx, state: &mut RoomState, ev: &StoredRow, pending: PendingCommit) -> Result<(), BotError> {
    if ev.seq != pending.seq {
        // Not the commit we are waiting for (a duplicate-detected replay or an
        // older own commit): keep waiting.
        state.pending = Some(pending);
        return Ok(());
    }
    match guarded(&mut state.device, ctx.own, |d| d.merge_pending().map_err(drop))? {
        Ok(()) => {}
        Err(()) => {
            emit(&serde_json::json!({ "event": "own_commit_merge_rejected", "room": state.room, "seq": ev.seq }));
            return Ok(());
        }
    }
    state.epoch = ev.epoch + 1;
    state.dirty = true;
    emit(&serde_json::json!({ "event": "own_commit_merged", "room": state.room, "seq": ev.seq, "epoch": state.epoch }));
    // The merged group state must be on disk before any Welcome derived from
    // it reaches a peer (same rule as echo encrypts).
    flush(ctx, state)?;
    if let Some(welcome) = pending.welcome {
        let client_id = format!("{}-welcome-{}", ctx.own, ev.seq);
        let post = EventPost {
            device: ctx.own, client_id: &client_id, kind: "welcome", epoch: state.epoch, revision: None,
            group_id: &state.room, targets: pending.targets.clone(), members: Vec::new(), bytes: welcome,
        };
        match ctx.client.post_event(&state.room, &post) {
            Ok(resp) => emit(&serde_json::json!({
                "event": "welcome_sent", "room": state.room, "seq": resp.seq, "targets": pending.targets, "epoch": state.epoch,
            })),
            Err(err) => emit(&serde_json::json!({
                "event": "welcome_failed", "room": state.room, "targets": pending.targets, "error": err.to_string(),
            })),
        }
    }
    Ok(())
}

/// On-disk envelope around `Device::export_identity` (signer only, no group).
#[derive(serde::Serialize, serde::Deserialize)]
struct IdentityEnvelope {
    version: u32,
    device: String,
    identity: serde_json::Value,
}
const IDENTITY_VERSION: u32 = 1;

fn write_identity(path: &Path, device: &str, dev: &Device) -> Result<(), BotError> {
    let mut bytes = dev.export_identity(device).map_err(|_| BotError::Local("identity export rejected"))?;
    let env = IdentityEnvelope {
        version: IDENTITY_VERSION, device: device.to_string(),
        identity: serde_json::from_slice(&bytes).map_err(|_| BotError::Local("identity export json"))?,
    };
    let mut raw = serde_json::to_vec(&env).map_err(|_| BotError::Local("identity envelope json"))?;
    bytes.zeroize();
    let written = write_state_file(path, &raw);
    raw.zeroize();
    written
}

/// A fresh, group-less device from the identity file (fail-closed like `load_state`).
fn load_identity(path: &Path, device: &str) -> Result<Device, BotError> {
    let mut raw = std::fs::read(path).map_err(|_| BotError::Local("identity file unreadable"))?;
    let env: IdentityEnvelope = serde_json::from_slice(&raw).map_err(|_| BotError::Local("identity file corrupt"))?;
    if env.version != IDENTITY_VERSION || env.device != device {
        return Err(BotError::Local("identity file is for another version/device"));
    }
    let mut bytes = serde_json::to_vec(&env.identity).map_err(|_| BotError::Local("identity file corrupt"))?;
    let dev = Device::new_with_identity(device, &bytes);
    raw.zeroize();
    bytes.zeroize();
    dev.map_err(|_| BotError::Local("identity import rejected"))
}

/// One-shot migration (#372 P1→P2): split the signer out of an existing
/// single-room `--state-file` into `--identity-file`. The room state file is
/// left untouched (it still resumes that room); the identity file lets the
/// same device found or join further rooms.
pub fn extract_identity(state_file: &Path, room: &str, device: &str, identity_file: &Path) -> Result<(), BotError> {
    let (mut dev, cursor, epoch, joined, _) = load_state(Some(state_file), room, device)?
        .ok_or(BotError::Local("state file not found"))?;
    if identity_file.exists() {
        return Err(BotError::Local("identity file already exists; refusing to overwrite"));
    }
    write_identity(identity_file, device, &dev)?;
    // Prove the split: the identity file yields the same signer, without a group.
    let mut check = load_identity(identity_file, device)?;
    let (a, b) = (dev.public_key().map_err(|_| BotError::Local("public key"))?, check.public_key().map_err(|_| BotError::Local("public key"))?);
    if a != b {
        return Err(BotError::Local("identity file does not reproduce the signer"));
    }
    emit(&serde_json::json!({
        "event": "identity_extracted", "device": device, "room": room, "public_key": hex(&a),
        "identity_file": identity_file.display().to_string(), "cursor": cursor, "epoch": epoch, "joined": joined,
    }));
    Ok(())
}

/// Steward mode (#372 P2): one identity, N rooms under `rooms_dir`
/// (`<room>.state`, optional `<room>.mode`), commands via `cmd/`.
pub struct StewardOptions {
    pub base: String,
    pub device: String,
    pub access: api::Access,
    pub identity_file: PathBuf,
    pub rooms_dir: PathBuf,
    pub responder: Option<responder::Config>,
}

pub struct Steward {
    device: String,
    rooms_dir: PathBuf,
    identity_file: PathBuf,
    /// #423: the responder speaks room frames, so any number of rooms may be
    /// in `agent` mode. Off = at most one (the single-room wire).
    multi_agent: bool,
}

fn room_state_path(dir: &Path, room: &str) -> PathBuf { dir.join(format!("{room}.state")) }
fn room_mode_path(dir: &Path, room: &str) -> PathBuf { dir.join(format!("{room}.mode")) }

fn read_mode(dir: &Path, room: &str) -> Mode {
    std::fs::read_to_string(room_mode_path(dir, room)).ok().and_then(|s| Mode::parse(&s)).unwrap_or(Mode::Silent)
}

/// Rooms known on disk: every `<room>.state` whose stem is a relay identifier.
fn rooms_on_disk(dir: &Path) -> Result<Vec<String>, BotError> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir).map_err(|_| BotError::Local("rooms dir unreadable"))? {
        let entry = entry.map_err(|_| BotError::Local("rooms dir unreadable"))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if let Some(room) = name.strip_suffix(".state") {
            if api::is_identifier(room) { out.push(room.to_string()); }
        }
    }
    out.sort();
    Ok(out)
}

fn load_room(dir: &Path, room: &str, device: &str) -> Result<RoomState, BotError> {
    let path = room_state_path(dir, room);
    let (dev, cursor, epoch, joined, echoes) = load_state(Some(&path), room, device)?
        .ok_or(BotError::Local("room state file vanished"))?;
    let halted = refused_marker_path(&path).exists();
    Ok(RoomState {
        sync: RoomSync { room: room.to_string(), cursor, epoch, joined, joinable: true, dirty: false, acked: cursor, ack_sent: 0, ack_disabled: false, halted },
        echoes, retry: VecDeque::new(), device: dev, state_path: Some(path), mode: read_mode(dir, room), pending: None,
    })
}

pub fn run_steward(opts: StewardOptions) -> Result<(), BotError> {
    let max_secs = std::env::var("NATIVE_MLS_BOT_MAX_SECS").ok().and_then(|raw| raw.parse().ok()).unwrap_or(DEFAULT_MAX_SECS);
    let deadline = if max_secs == 0 { None } else {
        Some(Instant::now().checked_add(Duration::from_secs(max_secs)).ok_or(BotError::Local("NATIVE_MLS_BOT_MAX_SECS out of range"))?)
    };
    let client = Client::with_access(&opts.base, opts.access.clone());
    let ctx = Ctx { client: &client, own: &opts.device };
    std::fs::create_dir_all(opts.rooms_dir.join("cmd")).map_err(|_| BotError::Local("rooms dir create"))?;
    std::fs::create_dir_all(opts.rooms_dir.join("out")).map_err(|_| BotError::Local("rooms dir create"))?;
    // The identity must load before anything else: a steward that cannot
    // reproduce its signer must not touch any room.
    let mut probe = load_identity(&opts.identity_file, &opts.device)?;
    let public_key = probe.public_key().map_err(|_| BotError::Local("public key"))?;
    drop(probe);
    let mut rooms = Vec::new();
    for room in rooms_on_disk(&opts.rooms_dir)? {
        rooms.push(load_room(&opts.rooms_dir, &room, &opts.device)?);
    }
    let multi_agent = opts.responder.as_ref().is_some_and(|c| c.room_frames);
    let agent_rooms = rooms.iter().filter(|r| r.mode == Mode::Agent).count();
    if agent_rooms > 1 && !multi_agent {
        return Err(BotError::Local("more than one room in agent mode; the responder serves exactly one (start with --room-frames for several)"));
    }
    emit(&serde_json::json!({
        "event": "steward_ready", "device": opts.device, "public_key": hex(&public_key),
        "rooms": rooms.iter().map(|r| serde_json::json!({"room": r.room, "joined": r.joined, "mode": r.mode.name(), "halted": r.halted})).collect::<Vec<_>>(),
        "max_secs": max_secs,
    }));
    let mut agent: Option<Responder> = match &opts.responder {
        Some(config) => {
            let responder = Responder::spawn(config.clone(), Some(&opts.rooms_dir.join("responder.state")))?;
            emit(&serde_json::json!({
                "event": "agent_started", "device": opts.device, "owner_actor": config.owner_actor,
                "agent_room": rooms.iter().find(|r| r.mode == Mode::Agent).map(|r| r.room.clone()),
                "agent_rooms": rooms.iter().filter(|r| r.mode == Mode::Agent).map(|r| r.room.clone()).collect::<Vec<_>>(),
                "room_frames": config.room_frames,
            }));
            Some(responder)
        }
        None => None,
    };
    let steward = Steward { device: opts.device.clone(), rooms_dir: opts.rooms_dir.clone(), identity_file: opts.identity_file.clone(), multi_agent };
    run_loop(&ctx, &mut rooms, &mut agent, deadline, Some(&steward))
}

/// One operator command (written by the CLI into `cmd/<id>.json`).
#[derive(serde::Deserialize, serde::Serialize, Clone, Debug)]
pub struct Command {
    pub op: String,
    pub room: String,
    #[serde(default)]
    pub arg: String,
}

impl Steward {
    /// Serve the oldest queued command, if any; its outcome lands in
    /// `out/<id>.json` and the request file is removed.
    fn serve_one(&self, ctx: &Ctx, rooms: &mut Vec<RoomState>) -> Result<(), BotError> {
        let cmd_dir = self.rooms_dir.join("cmd");
        let mut names: Vec<String> = match std::fs::read_dir(&cmd_dir) {
            Ok(entries) => entries.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.ends_with(".json")).collect(),
            Err(_) => return Ok(()),
        };
        if names.is_empty() { return Ok(()); }
        names.sort();
        let name = names.remove(0);
        let path = cmd_dir.join(&name);
        let outcome = match std::fs::read(&path).ok().and_then(|raw| serde_json::from_slice::<Command>(&raw).ok()) {
            None => serde_json::json!({ "ok": false, "error": "bad_command" }),
            Some(cmd) => match self.execute(ctx, rooms, &cmd) {
                Ok(value) => { let mut v = value; v["ok"] = serde_json::Value::Bool(true); v }
                Err(err) => serde_json::json!({ "ok": false, "error": err.to_string(), "op": cmd.op, "room": cmd.room }),
            },
        };
        emit(&serde_json::json!({ "event": "steward_command", "id": name, "outcome": outcome }));
        let raw = serde_json::to_vec(&outcome).map_err(|_| BotError::Local("outcome json"))?;
        write_state_file(&self.rooms_dir.join("out").join(&name), &raw)?;
        let _ = std::fs::remove_file(&path);
        Ok(())
    }

    fn execute(&self, ctx: &Ctx, rooms: &mut Vec<RoomState>, cmd: &Command) -> Result<serde_json::Value, BotError> {
        api::require_identifier("room must match [A-Za-z0-9_-]{1,64}", &cmd.room)?;
        let idx = rooms.iter().position(|r| r.room == cmd.room);
        match cmd.op.as_str() {
            // Found a group locally; the relay room appears with the first commit (invite).
            "create" => {
                if idx.is_some() { return Err(BotError::Local("room already known to this steward")); }
                let mut dev = load_identity(&self.identity_file, &self.device)?;
                dev.create().map_err(|_| BotError::Local("group create rejected"))?;
                let path = room_state_path(&self.rooms_dir, &cmd.room);
                let mode = Mode::parse(&cmd.arg).unwrap_or(Mode::Silent);
                if mode == Mode::Agent && !self.multi_agent && rooms.iter().any(|r| r.mode == Mode::Agent) {
                    return Err(BotError::Local("another room is already in agent mode"));
                }
                persist_state(&path, &cmd.room, &self.device, &mut dev, 0, 0, true, 0)?;
                std::fs::write(room_mode_path(&self.rooms_dir, &cmd.room), mode.name()).map_err(|_| BotError::Local("mode file write"))?;
                rooms.push(RoomState {
                    sync: RoomSync { room: cmd.room.clone(), cursor: 0, epoch: 0, joined: true, joinable: true, dirty: false, acked: 0, ack_sent: 0, ack_disabled: false, halted: false },
                    echoes: 0, retry: VecDeque::new(), device: dev, state_path: Some(path), mode, pending: None,
                });
                Ok(serde_json::json!({ "op": "create", "room": cmd.room, "mode": mode.name(), "epoch": 0 }))
            }
            // Publish a key package so a member can invite this device; joins on the Welcome.
            "join" => {
                if idx.is_some() { return Err(BotError::Local("room already known to this steward")); }
                let mut dev = load_identity(&self.identity_file, &self.device)?;
                let kp = dev.key_package().map_err(|_| BotError::Local("key package generation"))?;
                let key_ref = api::ref_hex(&kp);
                let path = room_state_path(&self.rooms_dir, &cmd.room);
                persist_state(&path, &cmd.room, &self.device, &mut dev, 0, 0, false, 0)?;
                let stored = ctx.client.post_key_packages(&cmd.room, &self.device, &[(key_ref.as_str(), kp)])?;
                std::fs::write(room_mode_path(&self.rooms_dir, &cmd.room), Mode::Silent.name()).map_err(|_| BotError::Local("mode file write"))?;
                rooms.push(RoomState {
                    sync: RoomSync { room: cmd.room.clone(), cursor: 0, epoch: 0, joined: false, joinable: true, dirty: false, acked: 0, ack_sent: 0, ack_disabled: false, halted: false },
                    echoes: 0, retry: VecDeque::new(), device: dev, state_path: Some(path), mode: Mode::Silent, pending: None,
                });
                Ok(serde_json::json!({ "op": "join", "room": cmd.room, "key_ref": key_ref, "stored": stored }))
            }
            "invite" | "remove" => {
                let state = idx.map(|i| &mut rooms[i]).ok_or(BotError::Local("unknown room; create or join it first"))?;
                api::require_identifier("target must match [A-Za-z0-9_-]{1,64}", &cmd.arg)?;
                if !state.joined { return Err(BotError::Local("not a member of this room yet")); }
                if state.halted { return Err(BotError::Local("room is halted")); }
                if state.pending.is_some() { return Err(BotError::Local("an own commit is still pending; try again after it echoes")); }
                let own = ctx.own.to_string();
                let mut key_source = serde_json::Value::Null;
                let (commit, welcome) = if cmd.op == "invite" {
                    // #380 P5: a room-scoped package first (bots `room join`,
                    // iOS 「참여 요청」); otherwise the device's room-independent
                    // lobby package the app tops up on launch.
                    let pkg = match ctx.client.consume_key_package(&cmd.room, &cmd.arg, &own)? {
                        Some(pkg) => { key_source = "room".into(); pkg }
                        None => match ctx.client.consume_lobby_key_package(&cmd.room, &cmd.arg, &own)? {
                            Some(pkg) => { key_source = "lobby".into(); pkg }
                            None => return Err(BotError::Detail(format!(
                                "no key package for {} in room {} or in the lobby (앱을 한 번 열어 로비 키를 보충하세요)", cmd.arg, cmd.room
                            ))),
                        },
                    };
                    if api::ref_hex(&pkg.bytes) != pkg.key_ref {
                        return Err(BotError::Local("consumed key package bytes do not match its sha256 ref"));
                    }
                    let framed = match guarded(&mut state.device, &own, |d| d.invite_with_commit(&pkg.bytes).map_err(drop))? {
                        Ok(f) => f, Err(()) => return Err(BotError::Local("invite rejected by the facade")),
                    };
                    if framed.len() < 4 { return Err(BotError::Local("invite frame too short")); }
                    let n = u32::from_le_bytes(framed[0..4].try_into().map_err(|_| BotError::Local("invite frame"))?) as usize;
                    if framed.len() < 4 + n { return Err(BotError::Local("invite frame length")); }
                    (framed[4..4 + n].to_vec(), Some(framed[4 + n..].to_vec()))
                } else {
                    let roster = state.device.members().ok().and_then(|f| policy::parse_roster(&f))
                        .ok_or(BotError::Local("roster unavailable"))?;
                    let key = roster.iter().find(|m| m.id == cmd.arg).map(|m| m.key.clone())
                        .ok_or(BotError::Local("target is not a member of this room"))?;
                    let commit = match guarded(&mut state.device, &own, |d| d.remove_member_pending(&key).map_err(drop))? {
                        Ok(c) => c, Err(()) => return Err(BotError::Local("remove rejected by the facade")),
                    };
                    (commit, None)
                };
                let expected = state.device.members_after_pending().ok().and_then(|f| policy::parse_roster(&f))
                    .ok_or(BotError::Local("post-commit roster unavailable"))?;
                let members: Vec<api::MemberWire> = expected.iter()
                    .map(|m| api::MemberWire { device: &m.id, actor: responder::actor_of(&m.id) }).collect();
                let client_id = format!("{}-{}-{}", own, cmd.op, now_millis());
                let post = EventPost {
                    device: &own, client_id: &client_id, kind: "commit", epoch: state.epoch, revision: None,
                    group_id: &cmd.room, targets: Vec::new(), members, bytes: commit,
                };
                match ctx.client.post_event(&cmd.room, &post) {
                    Ok(resp) => {
                        state.pending = Some(PendingCommit { seq: resp.seq, welcome, targets: vec![cmd.arg.clone()] });
                        let mut out = serde_json::json!({
                            "op": cmd.op, "room": cmd.room, "target": cmd.arg, "seq": resp.seq, "epoch": resp.epoch,
                            "members": expected.iter().map(|m| m.id.clone()).collect::<Vec<_>>(),
                            "note": "pending until the relay echoes the commit; the Welcome follows",
                        });
                        if !key_source.is_null() { out["key_source"] = key_source; }
                        Ok(out)
                    }
                    Err(err) => {
                        let _ = state.device.clear_pending();
                        Err(err)
                    }
                }
            }
            "members" => {
                let state = idx.map(|i| &rooms[i]).ok_or(BotError::Local("unknown room"))?;
                let roster = state.device.members().ok().and_then(|f| policy::parse_roster(&f)).unwrap_or_default();
                Ok(serde_json::json!({
                    "op": "members", "room": cmd.room, "joined": state.joined, "epoch": state.epoch, "cursor": state.cursor,
                    "mode": state.mode.name(), "halted": state.halted, "pending": state.pending.is_some(),
                    "members": roster.iter().map(|m| serde_json::json!({"device": m.id, "key": hex(&m.key)})).collect::<Vec<_>>(),
                }))
            }
            "mode" => {
                let mode = Mode::parse(&cmd.arg).ok_or(BotError::Local("mode must be agent, silent or alert"))?;
                let i = idx.ok_or(BotError::Local("unknown room"))?;
                if mode == Mode::Agent && !self.multi_agent && rooms.iter().enumerate().any(|(j, r)| j != i && r.mode == Mode::Agent) {
                    return Err(BotError::Local("another room is already in agent mode"));
                }
                std::fs::write(room_mode_path(&self.rooms_dir, &cmd.room), mode.name()).map_err(|_| BotError::Local("mode file write"))?;
                rooms[i].mode = mode;
                Ok(serde_json::json!({ "op": "mode", "room": cmd.room, "mode": mode.name() }))
            }
            // #389: tombstone the relay room (every member then reads 410 →
            // `room_closed`) and forget it here (state, mode, refusal marker).
            // The agent room and a room with an own commit in flight are
            // refused. A room this steward never joined, or one it was removed
            // from (403 `not_a_member`), is only forgotten locally; a room the
            // relay never saw (founded, never invited: 404) likewise.
            "close" => {
                let i = idx.ok_or(BotError::Local("unknown room"))?;
                if rooms[i].mode == Mode::Agent { return Err(BotError::Local("room is in agent mode; switch it to silent first")); }
                if rooms[i].pending.is_some() { return Err(BotError::Local("an own commit is still pending; try again after it echoes")); }
                let relay = if !rooms[i].joined {
                    "not_member"
                } else {
                    match ctx.client.close_room(&cmd.room, ctx.own) {
                        Ok(true) => "closed",
                        Ok(false) => "absent",
                        Err(api::RelayError::Api { status: 403, code }) if code == "not_a_member" => "not_member",
                        Err(err) => return Err(err),
                    }
                };
                let state_path = room_state_path(&self.rooms_dir, &cmd.room);
                for path in [refused_marker_path(&state_path), room_mode_path(&self.rooms_dir, &cmd.room),
                             state_path.with_extension("state.tmp"), state_path] {
                    match std::fs::remove_file(&path) {
                        Ok(()) => {}
                        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
                        Err(_) => return Err(BotError::Local("room file remove")),
                    }
                }
                rooms.remove(i);
                Ok(serde_json::json!({ "op": "close", "room": cmd.room, "relay": relay }))
            }
            "status" => Ok(serde_json::json!({
                "op": "status", "device": self.device,
                "rooms": rooms.iter().map(|r| serde_json::json!({
                    "room": r.room, "joined": r.joined, "mode": r.mode.name(), "epoch": r.epoch, "cursor": r.cursor,
                    "halted": r.halted, "pending": r.pending.is_some(),
                })).collect::<Vec<_>>(),
            })),
            _ => Err(BotError::Local("unknown op (create|join|invite|remove|close|members|mode|status)")),
        }
    }
}

fn now_millis() -> u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

/// CLI side of the queue: write `cmd/<id>.json`, wait for `out/<id>.json`.
pub fn request(rooms_dir: &Path, cmd: &Command, wait: Duration) -> Result<serde_json::Value, BotError> {
    let cmd_dir = rooms_dir.join("cmd");
    let out_dir = rooms_dir.join("out");
    if !cmd_dir.is_dir() || !out_dir.is_dir() {
        return Err(BotError::Local("rooms dir has no cmd/out queue — is the steward running with this --rooms-dir?"));
    }
    let id = format!("{}-{}.json", now_millis(), std::process::id());
    let raw = serde_json::to_vec(cmd).map_err(|_| BotError::Local("command json"))?;
    write_state_file(&cmd_dir.join(&id), &raw)?;
    let deadline = Instant::now() + wait;
    let out = out_dir.join(&id);
    loop {
        if let Ok(raw) = std::fs::read(&out) {
            let value: serde_json::Value = serde_json::from_slice(&raw).map_err(|_| BotError::Local("outcome json"))?;
            let _ = std::fs::remove_file(&out);
            return Ok(value);
        }
        if Instant::now() >= deadline {
            let _ = std::fs::remove_file(cmd_dir.join(&id));
            return Err(BotError::Local("timed out waiting for the steward (is it running?)"));
        }
        std::thread::sleep(POLL);
    }
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
                "halted": state.halted, "mode": state.mode.name(), "pending": state.pending.is_some(),
            })
        })
        .collect();
    // #423 (④ input): one GET per room per round — the polling cost grows with
    // the room count, so say it.
    emit(&serde_json::json!({ "event": "status", "rooms": rooms, "polls_per_round": rooms.len() }));
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

    /// Agent mode routing (#354): bot actors and attachments never become
    /// turns, the owner's approval reply is routed (not a turn), and a plain
    /// family message comes back as the worker's reply.
    #[test]
    fn route_to_agent_filters_and_answers() {
        const ECHO_WORKER: &str = r#"
import json, sys
for line in sys.stdin:
    cmd = json.loads(line)
    if cmd["type"] == "turn":
        print(json.dumps({"type": "result", "turn_id": cmd["turn_id"], "status": "complete", "session_id": "s", "text": "답:" + cmd["prompt"]}), flush=True)
"#;
        let config = responder::Config::new(responder::Transport::Argv(vec!["python3".into(), "-c".into(), ECHO_WORKER.into()]), "owner".into());
        let mut agent = Responder::spawn(config, None).unwrap_or_else(|e| panic!("spawn: {e}"));
        let mut state = joined_room("family", 4);
        let row = |seq: i64, device: &str, client_id: &str| StoredRow {
            seq, device: device.into(), client_id: client_id.into(), kind: "application".into(), epoch: 2,
            bytes: Vec::new(), sha256: String::new(), created_at: 0,
        };
        // 1. bot actor → skipped. 2. attachment → skipped. 3. owner approval reply → routed, unknown number.
        route_to_agent(&mut state, &row(5, "bot-other", "bot-other-echo-1x"), b"bot-other", b"hi", &mut agent).unwrap();
        route_to_agent(&mut state, &row(6, "owner-pc", "file-v1-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2"), b"owner-pc", b"\xff\xd8", &mut agent).unwrap();
        route_to_agent(&mut state, &row(7, "owner-pc", "owner-pc-c7"), b"owner-pc", "승인 1".as_bytes(), &mut agent).unwrap();
        route_to_agent(&mut state, &row(8, "mom-iphone-1", "mom-iphone-1-c8"), b"mom-iphone-1", "저녁 뭐 먹지".as_bytes(), &mut agent).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut got = Vec::new();
        while got.is_empty() && Instant::now() < deadline {
            got.extend(agent.pump().unwrap_or_else(|e| panic!("pump: {e}")));
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(got, vec![Outbound::Reply { seq: 8, text: "답:저녁 뭐 먹지".into() }], "only the family message became a turn");
        assert_eq!(agent_text(&Outbound::ApprovalResolved { n: 2, allowed: true }), "승인 #2: 허용했습니다.");
        assert!(agent_text(&Outbound::Uncertain { seq: 9, reason: "watchdog".into() }).contains("#9"));
        assert_eq!(agent_kind(&Outbound::Reply { seq: 1, text: String::new() }), "reply");
        assert_eq!(agent_kind(&Outbound::Interim { seq: 1, text: String::new() }), "interim");
        assert_eq!(agent_text(&Outbound::Notice { room: "r".into(), text: "⏰".into() }), "⏰");
        assert_eq!(agent_kind(&Outbound::Notice { room: "r".into(), text: String::new() }), "notice");
        // P4: a tool call is never room text.
        let call = Outbound::ToolCall { tool_id: "n1".into(), name: "room_status".into(), op: "status".into(), room: "-".into(), arg: String::new() };
        assert_eq!(agent_kind(&call), "tool_call");
        assert_eq!(agent_text(&call), "");
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
        canned_relay_with_status(bodies.into_iter().map(|b| (200, b)).collect())
    }

    /// `canned_relay` with an explicit status per reply (404 for "no key package").
    fn canned_relay_with_status(replies: Vec<(u16, String)>) -> (String, std::thread::JoinHandle<Vec<String>>) {
        use std::io::{Read, Write as _};
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        let base = format!("http://127.0.0.1:{}", listener.local_addr().expect("addr").port());
        let handle = std::thread::spawn(move || {
            let mut seen = Vec::new();
            for (status, body) in replies {
                let (mut stream, _) = listener.accept().expect("accept");
                let mut raw = Vec::new();
                let mut buf = [0u8; 1024];
                while !raw.windows(4).any(|w| w == b"\r\n\r\n") {
                    let n = stream.read(&mut buf).expect("read request");
                    assert!(n > 0, "eof before header terminator");
                    raw.extend_from_slice(&buf[..n]);
                }
                // Drain the body (Content-Length) so a POST is not reset mid-send.
                let header_end = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
                let head = String::from_utf8_lossy(&raw[..header_end]).to_string();
                let length: usize = head.lines().find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse().unwrap_or(0))).unwrap_or(0);
                while raw.len() < header_end + length {
                    let n = stream.read(&mut buf).expect("read body");
                    assert!(n > 0, "eof before body end");
                    raw.extend_from_slice(&buf[..n]);
                }
                let text = String::from_utf8_lossy(&raw).to_string();
                seen.push(text.lines().next().unwrap_or_default().to_string());
                let reason = if status == 200 { "OK" } else { "Not Found" };
                let resp = format!("HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\n\r\n{body}", body.len());
                stream.write_all(resp.as_bytes()).expect("write response");
            }
            seen
        });
        (base, handle)
    }

    fn joined_room(room: &str, cursor: i64) -> RoomState {
        joined_room_at(room, cursor, None)
    }
    fn joined_room_at(room: &str, cursor: i64, state_path: Option<PathBuf>) -> RoomState {
        RoomState {
            sync: RoomSync { room: room.into(), cursor, epoch: 2, joined: true, joinable: true, dirty: false, acked: cursor, ack_sent: cursor, ack_disabled: false, halted: false },
            echoes: 3, retry: VecDeque::new(), device: Device::new("bot-1").unwrap_or_else(|_| panic!("device new")), state_path, mode: Mode::Echo, pending: None,
        }
    }

    /// #268 end to end through `poll_room`: a page whose `first_seq` lies past
    /// the cursor halts the room before any event moves the cursor, writes the
    /// durable marker with reason `history_gap`, and the next poll never
    /// touches the relay. A contiguous page (`first_seq == cursor + 1`) does
    /// not halt.
    /// #366 2c: the send path through host-core keeps the bot's 409 handling —
    /// cas_mismatch queues the plaintext for the next poll (attempt 1), a reused
    /// dedup key is skipped, and the echo counter is persisted before each POST.
    #[test]
    fn publish_echo_queues_a_conflict_and_skips_a_reused_key() {
        let (base, server) = canned_relay_with_status(vec![
            (409, r#"{"error":"cas_mismatch"}"#.to_string()),
            (409, r#"{"error":"client_id_reuse"}"#.to_string()),
            (200, r#"{"seq":21,"epoch":2,"revision":1,"duplicate":false}"#.to_string()),
        ]);
        let client = Client::with_access(&base, api::Access::None);
        let ctx = Ctx { client: &client, own: "bot-1" };
        let path = state_path("send-2c");
        let mut state = joined_room_at("family", 4, Some(path.clone()));
        state.device.create().expect("a one-member group to encrypt in");
        publish_echo(&ctx, &mut state, b"hello", 0).unwrap_or_else(|e| panic!("conflict: {e}"));
        assert_eq!(state.retry.len(), 1, "cas_mismatch queues the plaintext");
        assert_eq!(state.retry[0], (b"hello".to_vec(), 1));
        publish_echo(&ctx, &mut state, b"again", 0).unwrap_or_else(|e| panic!("reuse: {e}"));
        assert_eq!(state.retry.len(), 1, "client_id_reuse is not replayed");
        publish_echo(&ctx, &mut state, b"third", 0).unwrap_or_else(|e| panic!("sent: {e}"));
        assert_eq!(state.echoes, 6, "three dedup keys reserved after 3 earlier echoes");
        assert!(!state.dirty, "persisted before each POST");
        let on_disk: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).expect("state file")).expect("json");
        assert_eq!(on_disk["echoes"], 6);
        let seen = server.join().expect("relay");
        assert_eq!(seen.len(), 3);
        assert!(seen.iter().all(|line| line.starts_with("POST /v2/rooms/family/events")), "{seen:?}");
        let _ = std::fs::remove_file(&path);
    }

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
        let ctx = Ctx { client: &client, own: "bot-1" };

        // Contiguous history: no halt.
        let mut contiguous = joined_room_at("family", 4, Some(path.clone()));
        poll_room(&ctx, &mut contiguous, &mut None).unwrap_or_else(|e| panic!("contiguous poll: {e}"));
        assert!(!contiguous.halted, "first_seq == cursor + 1 is contiguous");
        assert!(!marker.exists());

        // Pruned gap 5..=9: halt, cursor untouched, marker durable.
        let mut state = joined_room_at("family", 4, Some(path.clone()));
        poll_room(&ctx, &mut state, &mut None).unwrap_or_else(|e| panic!("gap poll: {e}"));
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
        poll_room(&ctx, &mut state, &mut None).unwrap_or_else(|e| panic!("halted poll: {e}"));
        assert_eq!(seen.len(), 2);
        assert!(seen.iter().all(|line| line.starts_with("GET /v2/rooms/family/events?device=bot-1&after=4")), "{seen:?}");
        let _ = std::fs::remove_file(&marker);
    }

    /// #392: transport-level failures are transient, contract errors are not;
    /// the backoff doubles from 0.5 s and stops at 30 s.
    #[test]
    fn transient_relay_errors_and_backoff() {
        use native_mls_host::http::HttpError;
        let reset = std::io::Error::from(std::io::ErrorKind::ConnectionReset);
        assert!(is_transient(&BotError::Http(HttpError::Io(reset))));
        assert!(is_transient(&BotError::Http(HttpError::BadResponse("eof"))));
        assert!(is_transient(&BotError::Status { status: 503 }));
        assert!(is_transient(&BotError::Api { status: 502, code: "bad_gateway".into() }));
        assert!(!is_transient(&BotError::Http(HttpError::BadUrl)), "a bad base URL never heals");
        assert!(!is_transient(&BotError::Api { status: 500, code: "internal".into() }));
        assert!(!is_transient(&BotError::Api { status: 403, code: "device_not_allowed".into() }));
        assert!(!is_transient(&BotError::Local("state export rejected")));
        let waits: Vec<u64> = (1..=8).map(|n| relay_backoff(n).as_millis() as u64).collect();
        assert_eq!(waits, vec![500, 1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]);
        assert_eq!(relay_backoff(u32::MAX), RELAY_BACKOFF_MAX);
    }

    /// #392 through `run_loop`: a 503 while the relay restarts, then a normal
    /// page, then connection refused (the canned relay stops listening) — the
    /// loop survives all of it and ends only on its deadline.
    #[test]
    fn run_loop_waits_out_an_unreachable_relay() {
        let page = r#"{"epoch":2,"revision":1,"events":[],"first_seq":5}"#.to_string();
        let (base, server) = canned_relay_with_status(vec![(503, "unavailable".into()), (200, page)]);
        let client = Client::with_access(&base, api::Access::None);
        let ctx = Ctx { client: &client, own: "bot-1" };
        let mut rooms = vec![joined_room("family", 4)];
        let started = Instant::now();
        let err = run_loop(&ctx, &mut rooms, &mut None, Some(Instant::now() + Duration::from_millis(2500)), None)
            .expect_err("only the deadline ends the loop");
        assert!(err.to_string().contains("deadline"), "a transient relay error must not end the session: {err}");
        assert!(started.elapsed() >= Duration::from_millis(2400), "the loop ran until the deadline");
        let seen = server.join().expect("server thread");
        assert_eq!(seen.len(), 2, "{seen:?}");
        assert!(seen.iter().all(|l| l.starts_with("GET /v2/rooms/family/events?device=bot-1&after=4")), "{seen:?}");
        assert_eq!(rooms[0].cursor, 4, "nothing moved");
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("native-mls-bot-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("cmd")).expect("mkdir cmd");
        std::fs::create_dir_all(dir.join("out")).expect("mkdir out");
        dir
    }

    /// #372 P1→P2: the signer leaves a single-room state file as an identity
    /// file; the identity reproduces the key without the group; overwrite and a
    /// foreign device are refused.
    #[test]
    fn identity_file_splits_a_room_state_and_refuses_overwrite() {
        let dir = temp_dir("identity");
        let state = dir.join("family.state");
        let identity = dir.join("identity.json");
        let mut dev = Device::new("bot-1").unwrap_or_else(|_| panic!("device new"));
        dev.create().expect("create");
        let key = dev.public_key().expect("public key");
        persist_state(&state, "family", "bot-1", &mut dev, 3, 1, true, 0).expect("persist");
        extract_identity(&state, "family", "bot-1", &identity).expect("extract");
        let mut again = load_identity(&identity, "bot-1").expect("load identity");
        assert_eq!(again.public_key().expect("key"), key);
        again.create().expect("the identity carries no group, so a new one can be founded");
        assert!(extract_identity(&state, "family", "bot-1", &identity).is_err(), "no overwrite");
        assert!(load_identity(&identity, "bot-2").is_err(), "foreign device refused");
        // The room state still resumes as before.
        let (resumed, cursor, epoch, joined, _) = load_state(Some(&state), "family", "bot-1").expect("load").expect("present");
        assert_eq!((cursor, epoch, joined), (3, 1, true));
        drop(resumed);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// #372 P2 end to end without a relay beyond canned replies: the steward
    /// founds `family`, invites a real peer device from its published key
    /// package (consume → commit POST with the post-commit roster), merges on
    /// its own commit echo and sends the Welcome; the peer joins and decrypts.
    /// Then the roster shows both, mode changes are exclusive, and remove
    /// posts a bare commit.
    #[test]
    fn steward_founds_a_room_invites_a_peer_and_removes_it() {
        let dir = temp_dir("steward");
        let identity = dir.join("identity.json");
        write_identity(&identity, "bot-1", &Device::new("bot-1").unwrap_or_else(|_| panic!("device new"))).expect("identity");
        let mut peer = Device::new("owner-pc").unwrap_or_else(|_| panic!("peer"));
        let kp = peer.key_package().expect("peer key package");
        let kp_body = serde_json::json!({"ref": api::ref_hex(&kp), "bytes": crate::b64::encode(&kp), "expires_at": 0}).to_string();
        let (base, server) = canned_relay(vec![
            kp_body,
            r#"{"seq":1,"epoch":0,"revision":1,"duplicate":false}"#.into(),   // invite commit
            r#"{"seq":2,"epoch":1,"revision":2,"duplicate":false}"#.into(),   // welcome
            r#"{"seq":3,"epoch":1,"revision":3,"duplicate":false}"#.into(),   // remove commit
        ]);
        let client = Client::with_access(&base, api::Access::None);
        let ctx = Ctx { client: &client, own: "bot-1" };
        let steward = Steward { device: "bot-1".into(), rooms_dir: dir.clone(), identity_file: identity.clone(), multi_agent: false };
        let mut rooms = Vec::new();

        let out = steward.execute(&ctx, &mut rooms, &Command { op: "create".into(), room: "family".into(), arg: String::new() }).expect("create");
        assert_eq!(out["mode"], "silent", "D3: silent by default");
        assert!(rooms[0].joined && rooms[0].mode == Mode::Silent && dir.join("family.state").exists());
        assert_eq!(std::fs::read_to_string(dir.join("family.mode")).expect("mode file"), "silent");
        assert!(steward.execute(&ctx, &mut rooms, &Command { op: "create".into(), room: "family".into(), arg: String::new() }).is_err(), "no double create");

        let out = steward.execute(&ctx, &mut rooms, &Command { op: "invite".into(), room: "family".into(), arg: "owner-pc".into() }).expect("invite");
        assert_eq!(out["seq"], 1);
        assert_eq!(out["key_source"], "room", "#380 P5: a room-scoped package wins; the lobby is never asked (see request count below)");
        let members: Vec<String> = out["members"].as_array().expect("members").iter().map(|v| v.as_str().unwrap().to_string()).collect();
        assert_eq!(members, vec!["bot-1".to_string(), "owner-pc".to_string()]);
        assert!(rooms[0].pending.is_some());
        assert!(steward.execute(&ctx, &mut rooms, &Command { op: "invite".into(), room: "family".into(), arg: "owner-pc".into() }).is_err(), "one pending commit at a time");

        // The relay echoes our commit at seq 1: merge, epoch 0 → 1, Welcome goes out to the target.
        let echo = StoredRow { seq: 1, device: "bot-1".into(), client_id: "bot-1-invite-0".into(), kind: "commit".into(), epoch: 0,
            bytes: Vec::new(), sha256: String::new(), created_at: 0 };
        let pending = rooms[0].pending.take().expect("pending");
        let welcome = pending.welcome.clone().expect("invite carries a welcome");
        own_commit_echo(&ctx, &mut rooms[0], &echo, pending).expect("own commit echo");
        assert_eq!(rooms[0].epoch, 1);
        assert!(rooms[0].pending.is_none());

        peer.join(&welcome).expect("peer joins from the welcome");
        let ct = encrypt_frame(&mut rooms[0].device, "family", "bot-1", b"hello family").expect("encrypt");
        let (sender, plaintext) = decrypt_frame(&mut peer, "family", &ct).expect("peer decrypts");
        assert_eq!((sender.as_slice(), plaintext.as_slice()), (&b"bot-1"[..], &b"hello family"[..]));

        let out = steward.execute(&ctx, &mut rooms, &Command { op: "members".into(), room: "family".into(), arg: String::new() }).expect("members");
        let ids: Vec<&str> = out["members"].as_array().expect("list").iter().map(|m| m["device"].as_str().unwrap()).collect();
        assert_eq!(ids, vec!["bot-1", "owner-pc"]);

        // Mode: one agent room at a time.
        steward.execute(&ctx, &mut rooms, &Command { op: "mode".into(), room: "family".into(), arg: "agent".into() }).expect("mode agent");
        assert_eq!(rooms[0].mode, Mode::Agent);
        assert!(steward.execute(&ctx, &mut rooms, &Command { op: "create".into(), room: "two".into(), arg: "agent".into() }).is_err(), "second agent room refused");
        steward.execute(&ctx, &mut rooms, &Command { op: "mode".into(), room: "family".into(), arg: "silent".into() }).expect("mode silent");
        assert!(steward.execute(&ctx, &mut rooms, &Command { op: "mode".into(), room: "family".into(), arg: "loud".into() }).is_err());

        // Remove: bare commit, pending until echoed.
        let out = steward.execute(&ctx, &mut rooms, &Command { op: "remove".into(), room: "family".into(), arg: "owner-pc".into() }).expect("remove");
        assert_eq!(out["seq"], 3);
        assert_eq!(out["members"].as_array().expect("members").len(), 1);
        assert!(rooms[0].pending.as_ref().is_some_and(|p| p.welcome.is_none()));
        assert!(steward.execute(&ctx, &mut rooms, &Command { op: "remove".into(), room: "family".into(), arg: "nobody".into() }).is_err());

        let seen = server.join().expect("server thread");
        assert_eq!(seen.len(), 4, "{seen:?}");
        assert!(seen[0].starts_with("GET /v2/rooms/family/keypackages?device=owner-pc&consumer=bot-1"), "{}", seen[0]);
        assert!(seen[1].starts_with("POST /v2/rooms/family/events"), "{}", seen[1]);
        assert!(seen[2].starts_with("POST /v2/rooms/family/events"), "{}", seen[2]);
        assert!(seen[3].starts_with("POST /v2/rooms/family/events"), "{}", seen[3]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// #380 P5: a device without a room-scoped package is invited from its
    /// lobby package (room consume 404 → lobby consume → commit POST,
    /// `key_source: lobby`); when the lobby is empty too the error names
    /// both pools and nothing is posted.
    #[test]
    fn steward_invite_falls_back_to_the_lobby_key_package() {
        let dir = temp_dir("steward-lobby");
        let identity = dir.join("identity.json");
        write_identity(&identity, "bot-1", &Device::new("bot-1").unwrap_or_else(|_| panic!("device new"))).expect("identity");
        let mut peer = Device::new("owner-pc").unwrap_or_else(|_| panic!("peer"));
        let kp = peer.key_package().expect("peer key package");
        let kp_body = serde_json::json!({"ref": api::ref_hex(&kp), "bytes": crate::b64::encode(&kp), "expires_at": 0}).to_string();
        let none = r#"{"error":"no_live_key_package"}"#.to_string();
        let (base, server) = canned_relay_with_status(vec![
            (404, none.clone()),                                                    // family: room consume — nothing
            (200, kp_body),                                                         // family: lobby consume
            (200, r#"{"seq":1,"epoch":0,"revision":1,"duplicate":false}"#.into()),  // family: invite commit
            (404, none.clone()),                                                    // two: room consume — nothing
            (404, none),                                                            // two: lobby consume — nothing
        ]);
        let client = Client::with_access(&base, api::Access::None);
        let ctx = Ctx { client: &client, own: "bot-1" };
        let steward = Steward { device: "bot-1".into(), rooms_dir: dir.clone(), identity_file: identity.clone(), multi_agent: false };
        let mut rooms = Vec::new();

        steward.execute(&ctx, &mut rooms, &Command { op: "create".into(), room: "family".into(), arg: String::new() }).expect("create family");
        let out = steward.execute(&ctx, &mut rooms, &Command { op: "invite".into(), room: "family".into(), arg: "owner-pc".into() }).expect("invite via lobby");
        assert_eq!(out["key_source"], "lobby");
        assert_eq!(out["seq"], 1);
        assert_eq!(out["target"], "owner-pc");
        let members: Vec<String> = out["members"].as_array().expect("members").iter().map(|v| v.as_str().unwrap().to_string()).collect();
        assert_eq!(members, vec!["bot-1".to_string(), "owner-pc".to_string()]);
        assert!(rooms[0].pending.as_ref().is_some_and(|p| p.welcome.is_some() && p.targets == vec!["owner-pc".to_string()]));

        // Both pools empty: the error names the lobby, no commit is posted, no pending.
        steward.execute(&ctx, &mut rooms, &Command { op: "create".into(), room: "two".into(), arg: String::new() }).expect("create two");
        let err = steward.execute(&ctx, &mut rooms, &Command { op: "invite".into(), room: "two".into(), arg: "owner-pc".into() }).expect_err("no package anywhere");
        let text = err.to_string();
        assert!(text.contains("no key package for owner-pc in room two or in the lobby"), "{text}");
        assert!(text.contains("로비 키"), "{text}");
        assert!(rooms[1].pending.is_none());

        let seen = server.join().expect("server thread");
        assert_eq!(seen.len(), 5, "{seen:?}");
        assert_eq!(seen[0], "GET /v2/rooms/family/keypackages?device=owner-pc&consumer=bot-1 HTTP/1.1");
        assert_eq!(seen[1], "GET /v2/lobby/keypackages?device=owner-pc&consumer=bot-1&room=family HTTP/1.1");
        assert!(seen[2].starts_with("POST /v2/rooms/family/events"), "{}", seen[2]);
        assert_eq!(seen[3], "GET /v2/rooms/two/keypackages?device=owner-pc&consumer=bot-1 HTTP/1.1");
        assert_eq!(seen[4], "GET /v2/lobby/keypackages?device=owner-pc&consumer=bot-1&room=two HTTP/1.1");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// #389: `close` tombstones the relay room and forgets it locally (state,
    /// mode, refusal marker, in-memory entry). The agent room is refused
    /// without touching the relay; a room the relay never saw (404
    /// `no_such_room`) and one this steward was removed from (403
    /// `not_a_member`) are forgotten locally only; an unknown room is an error.
    #[test]
    fn steward_close_tombstones_the_relay_room_and_forgets_it() {
        let dir = temp_dir("steward-close");
        let identity = dir.join("identity.json");
        write_identity(&identity, "bot-1", &Device::new("bot-1").unwrap_or_else(|_| panic!("device new"))).expect("identity");
        let (base, server) = canned_relay_with_status(vec![
            (200, r#"{"closed":true}"#.into()),                 // family: closed
            (404, r#"{"error":"no_such_room"}"#.into()),        // two: founded, never invited
            (403, r#"{"error":"not_a_member"}"#.into()),        // three: removed from it
        ]);
        let client = Client::with_access(&base, api::Access::None);
        let ctx = Ctx { client: &client, own: "bot-1" };
        let steward = Steward { device: "bot-1".into(), rooms_dir: dir.clone(), identity_file: identity.clone(), multi_agent: false };
        let mut rooms = Vec::new();
        for room in ["family", "two", "three"] {
            steward.execute(&ctx, &mut rooms, &Command { op: "create".into(), room: room.into(), arg: String::new() }).expect("create");
        }
        // A stale refusal marker goes with the room.
        std::fs::write(refused_marker_path(&dir.join("family.state")), b"{}").expect("marker");

        let out = steward.execute(&ctx, &mut rooms, &Command { op: "close".into(), room: "family".into(), arg: String::new() }).expect("close family");
        assert_eq!((out["op"].as_str(), out["relay"].as_str()), (Some("close"), Some("closed")));
        for file in ["family.state", "family.mode", "family.state.refused"] {
            assert!(!dir.join(file).exists(), "{file} must be gone");
        }
        assert_eq!(rooms.iter().map(|r| r.room.as_str()).collect::<Vec<_>>(), vec!["two", "three"]);
        assert!(rooms_on_disk(&dir).expect("scan").iter().all(|r| r != "family"), "a restart must not resurrect it");

        // The agent room is refused before any request.
        steward.execute(&ctx, &mut rooms, &Command { op: "mode".into(), room: "two".into(), arg: "agent".into() }).expect("mode agent");
        assert!(steward.execute(&ctx, &mut rooms, &Command { op: "close".into(), room: "two".into(), arg: String::new() }).is_err());
        assert!(dir.join("two.state").exists());
        steward.execute(&ctx, &mut rooms, &Command { op: "mode".into(), room: "two".into(), arg: "silent".into() }).expect("mode silent");

        let out = steward.execute(&ctx, &mut rooms, &Command { op: "close".into(), room: "two".into(), arg: String::new() }).expect("close two");
        assert_eq!(out["relay"], "absent");
        let out = steward.execute(&ctx, &mut rooms, &Command { op: "close".into(), room: "three".into(), arg: String::new() }).expect("close three");
        assert_eq!(out["relay"], "not_member");
        assert!(rooms.is_empty());
        assert!(steward.execute(&ctx, &mut rooms, &Command { op: "close".into(), room: "family".into(), arg: String::new() }).is_err(), "unknown room");

        let seen = server.join().expect("server thread");
        assert_eq!(seen, vec![
            "POST /v2/rooms/family/close?device=bot-1 HTTP/1.1".to_string(),
            "POST /v2/rooms/two/close?device=bot-1 HTTP/1.1".to_string(),
            "POST /v2/rooms/three/close?device=bot-1 HTTP/1.1".to_string(),
        ]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// #372 P4: a worker `tool` frame runs through `run_loop` → `Steward::execute`
    /// and the `tool-result` reaches the worker (recorded to a file). Without a
    /// steward (legacy single-room session) the answer is `steward_only`.
    #[test]
    fn run_loop_executes_tool_calls_through_the_steward() {
        const TOOL_WORKER: &str = r#"
import json, os, sys
out = sys.argv[1]
for line in sys.stdin:
    cmd = json.loads(line)
    if cmd["type"] == "turn":
        name, room = cmd["prompt"].split(" ")
        args = {} if name == "room_status" else {"room": room}
        print(json.dumps({"type": "tool", "turn_id": cmd["turn_id"], "tool_id": "n1", "name": name, "arguments": args}), flush=True)
    elif cmd["type"] == "tool-result":
        with open(out + ".tmp", "w") as f:
            json.dump(cmd, f)
        os.replace(out + ".tmp", out)
        print(json.dumps({"type": "result", "turn_id": cmd["turn_id"], "status": "complete", "session_id": "s", "text": "done"}), flush=True)
"#;
        let dir = temp_dir("p4-tool");
        let identity = dir.join("identity.json");
        write_identity(&identity, "bot-1", &Device::new("bot-1").unwrap_or_else(|_| panic!("device new"))).expect("identity");
        let steward = Steward { device: "bot-1".into(), rooms_dir: dir.clone(), identity_file: identity, multi_agent: false };
        let (base, _server) = canned_relay(Vec::new());
        let client = Client::with_access(&base, api::Access::None);
        let ctx = Ctx { client: &client, own: "bot-1" };
        let spawn = |record: &Path| {
            let argv = vec!["python3".into(), "-c".into(), TOOL_WORKER.into(), record.to_string_lossy().into_owned()];
            Responder::spawn(responder::Config::new(responder::Transport::Argv(argv), "owner".into()), None).unwrap_or_else(|e| panic!("spawn: {e}"))
        };
        let read_record = |record: &Path| -> serde_json::Value {
            let deadline = Instant::now() + Duration::from_secs(10);
            while !record.exists() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(20));
            }
            serde_json::from_slice(&std::fs::read(record).expect("worker recorded the tool-result")).expect("record json")
        };

        // Steward present: the owner's turn asks room_create p4 → executed.
        let record = dir.join("tool-result-1.json");
        let mut agent = Some(spawn(&record));
        agent.as_mut().unwrap().offer(Inbound { room: "agent".into(), seq: 1, sender_device: "owner-pc".into(), text: "room_create p4".into() }).expect("offer");
        let mut rooms = Vec::new();
        // The loop ends on the deadline — or earlier, once it polls the new room
        // against the canned relay (which answers nothing); either way the tool
        // ran in the round before.
        run_loop(&ctx, &mut rooms, &mut agent, Some(Instant::now() + Duration::from_millis(1500)), Some(&steward)).expect_err("the loop ends with an error");
        let frame = read_record(&record);
        assert_eq!((frame["type"].as_str(), frame["tool_id"].as_str(), frame["turn_id"].as_str(), frame["ok"].as_bool()), (Some("tool-result"), Some("n1"), Some("t-1"), Some(true)));
        assert_eq!((frame["result"]["op"].as_str(), frame["result"]["room"].as_str(), frame["result"]["mode"].as_str(), frame["result"]["ok"].as_bool()), (Some("create"), Some("p4"), Some("silent"), Some(true)));
        assert!(rooms.iter().any(|r| r.room == "p4" && r.joined && r.mode == Mode::Silent), "the room exists in the loop's state");
        assert!(dir.join("p4.state").exists() && std::fs::read_to_string(dir.join("p4.mode")).expect("mode").trim() == "silent");
        drop(agent);

        // No steward (legacy session): refused on the port, nothing executed.
        let record = dir.join("tool-result-2.json");
        let mut agent = Some(spawn(&record));
        agent.as_mut().unwrap().offer(Inbound { room: "agent".into(), seq: 2, sender_device: "owner-pc".into(), text: "room_create p5".into() }).expect("offer");
        let mut rooms = Vec::new();
        let err = run_loop(&ctx, &mut rooms, &mut agent, Some(Instant::now() + Duration::from_millis(1500)), None).expect_err("deadline ends the loop");
        assert!(err.to_string().contains("deadline"), "{err}");
        let frame = read_record(&record);
        assert_eq!((frame["ok"].as_bool(), frame["error"].as_str(), frame["turn_id"].as_str()), (Some(false), Some("steward_only"), Some("t-2")));
        assert!(rooms.is_empty() && !dir.join("p5.state").exists());
        drop(agent);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The file queue: `request` writes `cmd/<id>.json`, `serve_one` answers in
    /// `out/<id>.json` and removes the request; a malformed request is answered
    /// with `bad_command`; a missing queue fails fast.
    #[test]
    fn command_queue_round_trips_and_rejects_garbage() {
        let dir = temp_dir("queue");
        let identity = dir.join("identity.json");
        write_identity(&identity, "bot-1", &Device::new("bot-1").unwrap_or_else(|_| panic!("device new"))).expect("identity");
        let steward = Steward { device: "bot-1".into(), rooms_dir: dir.clone(), identity_file: identity, multi_agent: false };
        let (base, _server) = canned_relay(Vec::new());
        let client = Client::with_access(&base, api::Access::None);
        let ctx = Ctx { client: &client, own: "bot-1" };
        let mut rooms = Vec::new();

        std::fs::write(dir.join("cmd").join("0-garbage.json"), b"{not json").expect("write");
        steward.serve_one(&ctx, &mut rooms).expect("serve garbage");
        let answered: serde_json::Value = serde_json::from_slice(&std::fs::read(dir.join("out").join("0-garbage.json")).expect("out")).expect("json");
        assert_eq!(answered["ok"], false);
        assert_eq!(answered["error"], "bad_command");
        assert!(!dir.join("cmd").join("0-garbage.json").exists());
        std::fs::remove_file(dir.join("out").join("0-garbage.json")).expect("consume the garbage outcome");

        let requester = {
            let dir = dir.clone();
            std::thread::spawn(move || request(&dir, &Command { op: "status".into(), room: "family".into(), arg: String::new() }, Duration::from_secs(5)))
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !requester.is_finished() {
            steward.serve_one(&ctx, &mut rooms).expect("serve");
            std::thread::sleep(Duration::from_millis(20));
        }
        let outcome = requester.join().expect("thread").expect("status outcome");
        assert_eq!(outcome["ok"], true);
        assert_eq!(outcome["rooms"].as_array().expect("rooms").len(), 0);
        assert!(std::fs::read_dir(dir.join("out")).expect("out dir").next().is_none(), "the requester removes its outcome");
        assert!(request(&dir.join("nope"), &Command { op: "status".into(), room: "family".into(), arg: String::new() }, Duration::from_millis(10)).is_err());
        let _ = std::fs::remove_dir_all(&dir);
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

    fn room_in(room: &str, mode: Mode) -> RoomState {
        let mut state = joined_room(room, 1);
        state.mode = mode;
        state
    }

    /// #423 routing table: single-room wire = the one agent room whatever the
    /// item says; room frames = the turn's own agent room, a notice also to
    /// an `alert` room, nothing to a silent room or an unknown one.
    #[test]
    fn target_room_routes_by_the_items_room() {
        let mut rooms = vec![room_in("soonwook", Mode::Agent), room_in("fleet", Mode::Alert), room_in("family", Mode::Silent), room_in("dungae", Mode::Agent)];
        let reply = Outbound::Reply { seq: 1, text: "x".into() };
        let notice = |room: &str| Outbound::Notice { room: room.into(), text: "n".into() };
        let pick = |rooms: &mut Vec<RoomState>, multi: bool, room: &str, item: &Outbound| target_room(rooms, multi, room, item).map(|r| r.room.clone());
        // Off: always the first agent room (the caller drops a notice for another room).
        assert_eq!(pick(&mut rooms, false, "dungae", &reply).as_deref(), Some("soonwook"));
        assert_eq!(pick(&mut rooms, false, "fleet", &notice("fleet")).as_deref(), Some("soonwook"));
        // On.
        assert_eq!(pick(&mut rooms, true, "dungae", &reply).as_deref(), Some("dungae"));
        assert_eq!(pick(&mut rooms, true, "", &reply).as_deref(), Some("soonwook"), "pre-#423 inbox / WorkerGone");
        assert_eq!(pick(&mut rooms, true, "fleet", &reply), None, "turn items never go to the alert room");
        assert_eq!(pick(&mut rooms, true, "fleet", &notice("fleet")).as_deref(), Some("fleet"));
        assert_eq!(pick(&mut rooms, true, "family", &notice("family")), None, "silent room stays silent");
        assert_eq!(pick(&mut rooms, true, "family", &reply), None, "switched to silent mid-turn = unsaid");
        assert_eq!(pick(&mut rooms, true, "nowhere", &notice("nowhere")), None);
    }

    #[test]
    fn alert_mode_parses_and_names() {
        assert_eq!(Mode::parse("alert"), Some(Mode::Alert));
        assert_eq!(Mode::Alert.name(), "alert");
        assert_eq!(Mode::parse(" agent\n"), Some(Mode::Agent));
        assert_eq!(Mode::parse("loud"), None);
    }
}
