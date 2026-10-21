//! Agent responder (#354 A1): replaces the echo with a ccc-node turn when the
//! session is started with a responder command. The responder is a child
//! process speaking the node-local JSON-lines port (`docs/FLEET-WORKER.md`,
//! `scripts/fleet_worker.py`): one `turn` at a time, `approval` requests
//! answered with `approve`/`deny`, and a terminal `result` whose `status` is
//! `complete` or `uncertain`.
//!
//! Division of labour (the MLS `Device` never leaves the poll thread):
//!   poll loop ──offer(seq, sender, text)──▶ Responder ──stdin JSON──▶ child
//!   poll loop ◀──pump(): Reply / ApprovalRequest / Resolved / Done ◀─stdout JSON─┘
//! The poll loop encrypts and POSTs every outbound text through the same
//! `publish_echo` path the echo used (relay client_id `<device>-echo-<n>`, so
//! human clients and other bots treat agent replies exactly like echoes).
//!
//! Rules fixed by the owner decision on #354 (2026-10-15):
//!   ②-B every application message is offered (no mention gate) — but never
//!       from a `bot*` actor (loop guard, same family as `is_echo_client_id`),
//!       never an attachment (`file-v1-<uuid>` client_id), never non-UTF-8;
//!   ③-B every non-bot actor may speak; execution rights are bound to the
//!       approval reply below, not to decryption (NATIVE-E2EE: decrypt ≠ run);
//!   ④-B approvals round-trip through the room as text: the bot posts
//!       `⚠️ 승인 필요 #n …`, and only the owner actor's reply `승인 n` /
//!       `거절 n` (or `approve n` / `deny n`) resolves it. Unanswered requests
//!       are denied by the worker's own `--approval-timeout`.
//!
//! Duplicate-execution guard (FLEET-BRIDGE: uncertain work is never re-run):
//! the active turn is written to `<state>.inbox.json` before the child sees it.
//! A restart that finds an active turn posts one "could not confirm" notice and
//! clears it — the message is never replayed into a second turn.
//!
//! Tools (#372 P4): the worker may ask the bot to run one steward room command
//! per turn (`tool` frame → `Outbound::ToolCall` → `Steward::execute` in the
//! poll loop → `tool_result()` → `tool-result` frame). Owner-only: the turn's
//! sender actor must be `owner_actor`; everything else is answered
//! `ok=false` on the port and never reaches the room.

use crate::api::BotError;
use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Bytes of one reply the bot will encrypt (above this the text is cut on a
/// char boundary and marked). Well under the facade's 256 KiB application cap
/// and the human clients' comfortable bubble size.
pub const DEFAULT_REPLY_MAX_BYTES: usize = 8 * 1024;
/// Turns waiting behind the active one; the rest are dropped with a log line
/// (a family room does not need a deep backlog, and the relay keeps the text).
pub const DEFAULT_QUEUE_MAX: usize = 8;
/// Watchdog on top of the worker's own `--turn-timeout`: if the child never
/// reports a result, the bot marks the turn uncertain itself.
pub const DEFAULT_TURN_SECS: u64 = 1200;
/// #474: `interim` messages one turn may post (progress lines between the
/// owner's message and the answer). Past this the rest of the turn's interims
/// are dropped — the final `result` still arrives — so a chatty or looping
/// worker cannot flood the room or the relay.
pub const DEFAULT_INTERIM_MAX: usize = 40;
/// Largest `text` field the bot sends to the worker (fleet_core MAX_TEXT_BYTES
/// is 16 KiB; the header the worker prepends needs a little room).
const PROMPT_MAX_BYTES: usize = 15 * 1024;

/// How the bot reaches the worker. Both carry the same JSON-lines port.
#[derive(Clone, Debug)]
pub enum Transport {
    /// Spawn the worker as a child (`[python3, fleet_worker.py, --workdir, …]`, no shell).
    /// The worker then runs as the bot's own user — fine for a dev box, not for a
    /// hardened deployment where the Codex login belongs to another account.
    Argv(Vec<String>),
    /// Connect to a unix socket the service manager owns (systemd `Accept=yes` +
    /// `StandardInput=socket`): the worker runs as the account that holds the
    /// AI credentials, the bot only ever sees the socket (0600, bot user).
    Unix(PathBuf),
}

#[derive(Clone, Debug)]
pub struct Config {
    pub transport: Transport,
    /// Actor whose text replies resolve approvals (`owner`).
    pub owner_actor: String,
    pub reply_max_bytes: usize,
    pub queue_max: usize,
    pub turn_secs: u64,
    /// #474: cap on `interim` messages per turn (0 = never post interims).
    pub interim_max: usize,
}

impl Config {
    pub fn new(transport: Transport, owner_actor: String) -> Self {
        Config {
            transport,
            owner_actor,
            reply_max_bytes: DEFAULT_REPLY_MAX_BYTES,
            queue_max: DEFAULT_QUEUE_MAX,
            turn_secs: DEFAULT_TURN_SECS,
            interim_max: DEFAULT_INTERIM_MAX,
        }
    }
}

/// What the poll loop must say in the room (it encrypts and POSTs; this
/// module never touches MLS).
#[derive(Debug, PartialEq, Eq)]
pub enum Outbound {
    /// The worker's answer for the turn started by relay seq `seq`.
    Reply { seq: i64, text: String },
    /// #474: a progress line the worker produced while the turn started by
    /// relay seq `seq` is still running (FLEET-WORKER `interim`). Posted like
    /// a reply; the turn stays active until its `result`.
    Interim { seq: i64, text: String },
    /// #474: unsolicited text for room `room` (FLEET-WORKER `notice`: push
    /// notifications, reminders, alerts the node raises outside any turn).
    /// The poll loop posts it only when `room` is the agent room.
    Notice { room: String, text: String },
    /// `⚠️ 승인 필요 #n` — ask the owner in the room.
    ApprovalRequest { n: u64, seq: i64, text: String },
    /// The worker closed approval `n` (owner answered, or its timeout denied).
    ApprovalResolved { n: u64, allowed: bool },
    /// The turn ended without a usable answer: `reason` is the worker's
    /// (`timeout`, `cancelled`, `runtime-error`, `rejected:<why>`, `watchdog`,
    /// `restart`) — never re-run.
    Uncertain { seq: i64, reason: String },
    /// The child is gone; the session should stop offering turns.
    WorkerGone { reason: String },
    /// P4: the worker asked for steward room command `op room arg` (already
    /// validated and owner-checked). Never posted to the room — the poll loop
    /// runs it and answers with `tool_result()`.
    ToolCall { tool_id: String, name: String, op: String, room: String, arg: String },
}

/// `room_status` takes no room; `Steward::execute` still shape-checks the
/// field, so a placeholder identifier rides along.
const STATUS_ROOM_PLACEHOLDER: &str = "-";

/// One decrypted application message the poll loop offers.
#[derive(Debug, Clone)]
pub struct Inbound {
    pub seq: i64,
    pub sender_device: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Offer {
    Started,
    Queued { depth: usize },
    Dropped { reason: &'static str },
}

enum Cmd {
    Line(String),
    Close,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug, PartialEq, Eq)]
struct ActiveTurn {
    seq: i64,
    turn_id: String,
    started_at: u64,
    /// P4 owner check for tool calls. Absent in inboxes written before P4
    /// (those only ever feed the restart notice, never a tool call).
    #[serde(default)]
    sender_device: String,
}

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct Inbox {
    version: u32,
    active: Option<ActiveTurn>,
}

const INBOX_VERSION: u32 = 1;

pub struct Responder {
    config: Config,
    /// Spawned worker (`Transport::Argv`); `None` over a socket.
    child: Option<Child>,
    to_child: Sender<Cmd>,
    from_child: Receiver<Result<serde_json::Value, String>>,
    inbox_path: Option<PathBuf>,
    active: Option<(ActiveTurn, Instant)>,
    queue: VecDeque<Inbound>,
    /// Approval number → (turn_id, worker approval_id).
    approvals: HashMap<u64, (String, String)>,
    next_approval: u64,
    gone: bool,
    /// Notices queued for the room (uncertain turn found at startup, etc.).
    startup_notices: Vec<Outbound>,
    /// P4: `tool_id` of the one tool call the poll loop still owes an answer.
    pending_tool: Option<String>,
    /// #474: `interim` messages already posted for the active turn.
    interim_sent: usize,
}

impl Responder {
    /// Spawn the worker. `state_file` (the bot's `--state-file`) locates the
    /// inbox next to it; without one the duplicate guard is memory-only.
    pub fn spawn(config: Config, state_file: Option<&Path>) -> Result<Self, BotError> {
        let (child, mut stdin, stdout): (Option<Child>, Box<dyn Write + Send>, Box<dyn std::io::Read + Send>) = match &config.transport {
            Transport::Argv(argv) => {
                let (program, args) = argv.split_first().ok_or(BotError::Local("responder argv empty"))?;
                let mut child = Command::new(program)
                    .args(args)
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::inherit())
                    .spawn()
                    .map_err(|_| BotError::Local("responder spawn failed"))?;
                let stdin = child.stdin.take().ok_or(BotError::Local("responder stdin"))?;
                let stdout = child.stdout.take().ok_or(BotError::Local("responder stdout"))?;
                (Some(child), Box::new(stdin), Box::new(stdout))
            }
            Transport::Unix(path) => {
                let stream = UnixStream::connect(path).map_err(|_| BotError::Local("responder socket connect failed"))?;
                let reader = stream.try_clone().map_err(|_| BotError::Local("responder socket clone"))?;
                (None, Box::new(stream), Box::new(reader))
            }
        };
        let (to_child, cmd_rx) = mpsc::channel::<Cmd>();
        std::thread::spawn(move || {
            for cmd in cmd_rx {
                match cmd {
                    Cmd::Line(line) => {
                        if stdin.write_all(line.as_bytes()).and_then(|_| stdin.write_all(b"\n")).and_then(|_| stdin.flush()).is_err() {
                            break;
                        }
                    }
                    Cmd::Close => break,
                }
            }
        });
        let (out_tx, from_child) = mpsc::channel();
        std::thread::spawn(move || {
            let reader = BufReader::with_capacity(64 * 1024, stdout);
            for line in reader.lines() {
                let item = match line {
                    Ok(line) if line.len() > 524_288 => Err("output frame too large".to_string()),
                    Ok(line) => serde_json::from_str::<serde_json::Value>(&line).map_err(|_| "output frame not json".to_string()),
                    Err(err) => Err(format!("stdout read: {err}")),
                };
                let fatal = item.is_err();
                if out_tx.send(item).is_err() || fatal {
                    break;
                }
            }
            let _ = out_tx.send(Err("worker stdout closed".to_string()));
        });
        let inbox_path = state_file.map(inbox_path);
        let mut responder = Responder {
            config,
            child,
            to_child,
            from_child,
            inbox_path,
            active: None,
            queue: VecDeque::new(),
            approvals: HashMap::new(),
            next_approval: 0,
            gone: false,
            startup_notices: Vec::new(),
            pending_tool: None,
            interim_sent: 0,
        };
        // A turn left active by an earlier run was never confirmed: say so
        // once, clear it, never re-run it.
        if let Some(previous) = responder.load_inbox()?.active {
            responder.startup_notices.push(Outbound::Uncertain { seq: previous.seq, reason: "restart".to_string() });
            responder.write_inbox(None)?;
        }
        Ok(responder)
    }

    pub fn owner_actor(&self) -> &str { &self.config.owner_actor }

    #[cfg(test)]
    fn is_gone(&self) -> bool { self.gone }

    /// Offer a decrypted room message. Starts the turn now or queues it.
    pub fn offer(&mut self, inbound: Inbound) -> Result<Offer, BotError> {
        if self.gone {
            return Ok(Offer::Dropped { reason: "worker_gone" });
        }
        if self.active.is_some() {
            if self.queue.len() >= self.config.queue_max {
                return Ok(Offer::Dropped { reason: "queue_full" });
            }
            self.queue.push_back(inbound);
            return Ok(Offer::Queued { depth: self.queue.len() });
        }
        self.start(inbound)?;
        Ok(Offer::Started)
    }

    /// Owner's `승인 n` / `거절 n`: route to the worker. `None` = unknown number.
    pub fn resolve(&mut self, n: u64, allow: bool) -> Option<bool> {
        let (turn_id, approval_id) = self.approvals.get(&n)?.clone();
        let kind = if allow { "approve" } else { "deny" };
        let line = serde_json::json!({ "type": kind, "turn_id": turn_id, "approval_id": approval_id }).to_string();
        let _ = self.to_child.send(Cmd::Line(line));
        Some(allow)
    }

    /// Drain worker output into room-bound items and start the next queued
    /// turn when the active one ends. Call once per poll round.
    pub fn pump(&mut self) -> Result<Vec<Outbound>, BotError> {
        let mut out = std::mem::take(&mut self.startup_notices);
        loop {
            match self.from_child.try_recv() {
                Ok(Ok(value)) => self.handle(value, &mut out)?,
                Ok(Err(reason)) => {
                    self.fail(reason, &mut out)?;
                    break;
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    self.fail("worker reader stopped".to_string(), &mut out)?;
                    break;
                }
            }
        }
        if let Some((turn, started)) = &self.active {
            if started.elapsed() > Duration::from_secs(self.config.turn_secs) {
                let seq = turn.seq;
                out.push(Outbound::Uncertain { seq, reason: "watchdog".to_string() });
                self.finish_active()?;
            }
        }
        if self.active.is_none() && !self.gone {
            if let Some(next) = self.queue.pop_front() {
                self.start(next)?;
            }
        }
        Ok(out)
    }

    fn start(&mut self, inbound: Inbound) -> Result<(), BotError> {
        let turn_id = format!("t-{}", inbound.seq);
        let active = ActiveTurn {
            seq: inbound.seq, turn_id: turn_id.clone(), started_at: now_secs(), sender_device: inbound.sender_device.clone(),
        };
        // Durable before the child sees it (FLEET-WORKER: the parent inbox is
        // the duplicate guard, not the port).
        self.write_inbox(Some(&active))?;
        self.active = Some((active, Instant::now()));
        self.interim_sent = 0;
        let line = serde_json::json!({
            "type": "turn",
            "turn_id": turn_id,
            "prompt": bounded(&inbound.text, PROMPT_MAX_BYTES),
            "session_id": serde_json::Value::Null,
            // fleet_worker validates `sender` as a Matrix-shaped id: the
            // native device id rides in the localpart under a fixed server
            // name, so the prompt header reads "보낸 사람: @<device>:hande".
            "sender": format!("@{}:hande", inbound.sender_device),
            "room_kind": "family",
        })
        .to_string();
        if self.to_child.send(Cmd::Line(line)).is_err() {
            self.gone = true;
            return Err(BotError::Local("responder stdin closed"));
        }
        Ok(())
    }

    fn handle(&mut self, value: serde_json::Value, out: &mut Vec<Outbound>) -> Result<(), BotError> {
        let kind = value.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if kind == "notice" {
            // #474: not tied to a turn (a reminder or alert the node raises on
            // its own), so it is read before the active-turn filter below.
            let room = value.get("room").and_then(|v| v.as_str()).unwrap_or("");
            let text = value.get("text").and_then(|v| v.as_str()).unwrap_or("").trim();
            if is_room_id(room) && !text.is_empty() {
                out.push(Outbound::Notice { room: room.to_string(), text: bounded_reply(text, self.config.reply_max_bytes) });
            }
            return Ok(());
        }
        let turn_id = value.get("turn_id").and_then(|v| v.as_str()).unwrap_or("");
        let Some((active, _)) = &self.active else {
            // Output for no active turn (late events after a watchdog): ignore.
            return Ok(());
        };
        if !turn_id.is_empty() && turn_id != active.turn_id {
            return Ok(());
        }
        let seq = active.seq;
        match kind {
            "approval" => {
                let approval_id = value.get("approval_id").and_then(|v| v.as_str()).unwrap_or("").to_string();
                if approval_id.is_empty() {
                    return Ok(());
                }
                self.next_approval += 1;
                let n = self.next_approval;
                self.approvals.insert(n, (active.turn_id.clone(), approval_id));
                let description = value.get("description").and_then(|v| v.as_str()).unwrap_or("");
                let action = value.get("action").and_then(|v| v.as_str()).unwrap_or("");
                // P4: a steward room tool shows its name and arguments (the
                // worker's free-text description could say anything).
                let summary = match action.strip_prefix("mcp__steward__") {
                    Some(tool) if tool.starts_with("room_") => steward_tool_summary(tool, value.get("arguments")),
                    _ => bounded(if description.is_empty() { action } else { description }, 2048),
                };
                let text = format!("⚠️ 승인 필요 #{n}: {summary}\n답장: 「승인 {n}」 또는 「거절 {n}」 ({} 만)", self.config.owner_actor);
                out.push(Outbound::ApprovalRequest { n, seq, text });
            }
            "tool" => {
                // P4: a room command request. Addressed to this turn only.
                let tool_id = value.get("tool_id").and_then(|v| v.as_str()).unwrap_or("");
                if turn_id.is_empty() || !is_tool_id(tool_id) {
                    return Ok(());
                }
                let turn_id = active.turn_id.clone();
                let name = value.get("name").and_then(|v| v.as_str()).unwrap_or("");
                let Some((op, room, arg)) = tool_command(name, value.get("arguments")) else {
                    self.send_tool_result(&turn_id, tool_id, Err("bad_arguments".to_string()));
                    return Ok(());
                };
                if actor_of(&active.sender_device) != self.config.owner_actor {
                    self.send_tool_result(&turn_id, tool_id, Err("owner_only".to_string()));
                    return Ok(());
                }
                if self.pending_tool.is_some() {
                    self.send_tool_result(&turn_id, tool_id, Err("busy".to_string()));
                    return Ok(());
                }
                self.pending_tool = Some(tool_id.to_string());
                out.push(Outbound::ToolCall { tool_id: tool_id.to_string(), name: name.to_string(), op, room, arg });
            }
            "approval-resolved" => {
                let approval_id = value.get("approval_id").and_then(|v| v.as_str()).unwrap_or("");
                let allowed = value.get("allowed").and_then(|v| v.as_bool()).unwrap_or(false);
                if let Some((n, _)) = self.approvals.iter().find(|(_, (_, id))| id == approval_id).map(|(n, v)| (*n, v.clone())) {
                    self.approvals.remove(&n);
                    out.push(Outbound::ApprovalResolved { n, allowed });
                }
            }
            "approval-denied" => {
                // Too large to show: the worker already denied it; nothing to ask.
            }
            "result" => {
                let status = value.get("status").and_then(|v| v.as_str()).unwrap_or("uncertain");
                if status == "complete" {
                    let text = value.get("text").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
                    if !text.is_empty() {
                        out.push(Outbound::Reply { seq, text: bounded_reply(&text, self.config.reply_max_bytes) });
                    }
                } else {
                    let reason = value.get("reason").and_then(|v| v.as_str()).unwrap_or("uncertain").to_string();
                    out.push(Outbound::Uncertain { seq, reason });
                    // FLEET-WORKER: an uncertain outcome retires the worker; it
                    // accepts no further turns. Treat the process as gone.
                    self.finish_active()?;
                    self.fail("worker retired after an uncertain turn".to_string(), out)?;
                    return Ok(());
                }
                self.finish_active()?;
            }
            "interim" => {
                // #474: a progress line for the active turn. Bounded like a
                // reply and capped per turn; the turn stays active.
                let text = value.get("text").and_then(|v| v.as_str()).unwrap_or("").trim();
                if !text.is_empty() && self.interim_sent < self.config.interim_max {
                    self.interim_sent += 1;
                    out.push(Outbound::Interim { seq, text: bounded_reply(text, self.config.reply_max_bytes) });
                }
            }
            "rejected" => {
                let reason = value.get("reason").and_then(|v| v.as_str()).unwrap_or("rejected");
                out.push(Outbound::Uncertain { seq, reason: format!("rejected:{reason}") });
                self.finish_active()?;
            }
            // `session`, `control`: informational.
            _ => {}
        }
        Ok(())
    }

    /// P4: answer the pending `Outbound::ToolCall` of the active turn. Any other
    /// `tool_id` (late answer after the turn ended, unknown id) is dropped.
    pub fn tool_result(&mut self, tool_id: &str, outcome: Result<serde_json::Value, String>) {
        let Some((active, _)) = &self.active else { return };
        if self.pending_tool.as_deref() != Some(tool_id) {
            return;
        }
        let turn_id = active.turn_id.clone();
        self.pending_tool = None;
        self.send_tool_result(&turn_id, tool_id, outcome);
    }

    fn send_tool_result(&self, turn_id: &str, tool_id: &str, outcome: Result<serde_json::Value, String>) {
        let line = match outcome {
            Ok(result) => serde_json::json!({ "type": "tool-result", "turn_id": turn_id, "tool_id": tool_id, "ok": true, "result": result }),
            Err(error) => serde_json::json!({ "type": "tool-result", "turn_id": turn_id, "tool_id": tool_id, "ok": false, "error": error }),
        };
        let _ = self.to_child.send(Cmd::Line(line.to_string()));
    }

    fn finish_active(&mut self) -> Result<(), BotError> {
        self.active = None;
        self.approvals.clear();
        self.pending_tool = None;
        self.write_inbox(None)
    }

    fn fail(&mut self, reason: String, out: &mut Vec<Outbound>) -> Result<(), BotError> {
        if self.gone {
            return Ok(());
        }
        self.gone = true;
        if let Some((turn, _)) = self.active.take() {
            out.push(Outbound::Uncertain { seq: turn.seq, reason: "worker_gone".to_string() });
            self.approvals.clear();
            self.pending_tool = None;
            self.write_inbox(None)?;
        }
        for dropped in self.queue.drain(..) {
            out.push(Outbound::Uncertain { seq: dropped.seq, reason: "worker_gone".to_string() });
        }
        out.push(Outbound::WorkerGone { reason });
        let _ = self.to_child.send(Cmd::Close);
        Ok(())
    }

    fn load_inbox(&self) -> Result<Inbox, BotError> {
        let Some(path) = &self.inbox_path else { return Ok(Inbox::default()) };
        match std::fs::read(path) {
            Ok(raw) => {
                let inbox: Inbox = serde_json::from_slice(&raw).map_err(|_| BotError::Local("inbox file corrupt"))?;
                if inbox.version != INBOX_VERSION {
                    return Err(BotError::Local("inbox file version"));
                }
                Ok(inbox)
            }
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(Inbox::default()),
            Err(_) => Err(BotError::Local("inbox file unreadable")),
        }
    }

    fn write_inbox(&self, active: Option<&ActiveTurn>) -> Result<(), BotError> {
        let Some(path) = &self.inbox_path else { return Ok(()) };
        let inbox = Inbox { version: INBOX_VERSION, active: active.cloned() };
        let raw = serde_json::to_vec(&inbox).map_err(|_| BotError::Local("inbox json"))?;
        let tmp = path.with_extension("inbox.tmp");
        let _ = std::fs::remove_file(&tmp);
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&tmp).map_err(|_| BotError::Local("inbox file create"))?;
        file.write_all(&raw).map_err(|_| BotError::Local("inbox file write"))?;
        file.sync_all().map_err(|_| BotError::Local("inbox file fsync"))?;
        drop(file);
        std::fs::rename(&tmp, path).map_err(|_| BotError::Local("inbox file rename"))?;
        Ok(())
    }
}

impl Drop for Responder {
    fn drop(&mut self) {
        let _ = self.to_child.send(Cmd::Close);
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn inbox_path(state_file: &Path) -> PathBuf {
    let mut name = state_file.as_os_str().to_os_string();
    name.push(".inbox.json");
    PathBuf::from(name)
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

// ---- pure helpers the poll loop uses before offering ----

/// relay-app rule: the actor is the device id up to the first `-`.
pub fn actor_of(device: &str) -> &str {
    device.split('-').next().unwrap_or(device)
}

/// `bot*` actors never trigger a turn (two agents would otherwise answer each
/// other until the room cap — the same hazard `is_echo_client_id` guards).
pub fn is_bot_actor(device: &str) -> bool {
    actor_of(device).starts_with("bot")
}

/// relay-app / iOS `AttachmentFormat`: `^file-v1-[a-f0-9-]{36}$`.
pub fn is_attachment_client_id(client_id: &str) -> bool {
    match client_id.strip_prefix("file-v1-") {
        Some(tail) => tail.len() == 36 && tail.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase() || b == b'-'),
        None => false,
    }
}

/// `승인 3` / `거절 3` / `approve #3` / `deny 3` → (n, allow). Anything else → None.
pub fn parse_approval_reply(text: &str) -> Option<(u64, bool)> {
    let trimmed = text.trim();
    let (word, rest) = trimmed.split_once(char::is_whitespace)?;
    let allow = match word {
        "승인" | "approve" | "허용" => true,
        "거절" | "deny" | "거부" => false,
        _ => return None,
    };
    let digits = rest.trim().trim_start_matches('#');
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok().map(|n| (n, allow))
}

/// #474 `notice` room: the relay identifier rule `[A-Za-z0-9_-]{1,64}`.
fn is_room_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// P4 `tool_id`: `[A-Za-z0-9_-]{1,128}` (a worker nonce; echoed back verbatim).
fn is_tool_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 128 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// P4: map a worker `tool` frame (`name`, `arguments`) to a steward command
/// `(op, room, arg)`. `None` = bad name, missing/extra key, or a value outside
/// `[A-Za-z0-9_-]{1,64}` (the relay identifier rule every field must meet).
/// A missing `arguments` counts as `{}`; anything but an object is rejected.
pub fn tool_command(name: &str, arguments: Option<&serde_json::Value>) -> Option<(String, String, String)> {
    let args: HashMap<&str, &str> = match arguments {
        None | Some(serde_json::Value::Null) => HashMap::new(),
        Some(serde_json::Value::Object(map)) => map
            .iter()
            .map(|(k, v)| v.as_str().filter(|s| crate::api::is_identifier(s)).map(|s| (k.as_str(), s)))
            .collect::<Option<_>>()?,
        Some(_) => return None,
    };
    let (op, keys): (&str, &[&str]) = match name {
        "room_create" => ("create", &["room", "mode"]),
        "room_join" => ("join", &["room"]),
        "room_invite" => ("invite", &["room", "device"]),
        "room_remove" => ("remove", &["room", "device"]),
        "room_close" => ("close", &["room"]),
        "room_members" => ("members", &["room"]),
        "room_mode" => ("mode", &["room", "mode"]),
        "room_status" => ("status", &[]),
        _ => return None,
    };
    if args.keys().any(|k| !keys.contains(k)) {
        return None;
    }
    let room = match op {
        "status" => STATUS_ROOM_PLACEHOLDER,
        _ => args.get("room").copied()?,
    };
    let arg = match op {
        "invite" | "remove" => args.get("device").copied()?,
        "mode" => args.get("mode").copied().filter(|m| matches!(*m, "agent" | "silent"))?,
        "create" => match args.get("mode").copied() {
            None => "silent",
            Some(mode @ ("agent" | "silent")) => mode,
            Some(_) => return None,
        },
        _ => "",
    };
    Some((op.to_string(), room.to_string(), arg.to_string()))
}

/// Approval line for a steward room tool: `방 명령 room_invite · room=family · device=…`
/// (keys sorted, each value cut at 64 bytes, at most 8 pairs).
fn steward_tool_summary(tool: &str, arguments: Option<&serde_json::Value>) -> String {
    let mut text = format!("방 명령 {}", bounded(tool, 64));
    if let Some(serde_json::Value::Object(map)) = arguments {
        let mut keys: Vec<&String> = map.keys().collect();
        keys.sort();
        for key in keys.into_iter().take(8) {
            let value = match &map[key] {
                serde_json::Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            text.push_str(&format!(" · {}={}", bounded(key, 32), bounded(&value, 64)));
        }
    }
    text
}

/// Cut on a char boundary at `max` bytes.
fn bounded(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_string();
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_string()
}

fn bounded_reply(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_string();
    }
    let marker = "\n…(길어서 줄임)";
    let mut cut = bounded(text, max.saturating_sub(marker.len()));
    cut.push_str(marker);
    cut
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn actor_and_bot_rules() {
        assert_eq!(actor_of("owner-iphone-27a879"), "owner");
        assert_eq!(actor_of("bot-gongmyoung"), "bot");
        assert_eq!(actor_of("noprefix"), "noprefix");
        assert!(is_bot_actor("bot-gongmyoung"));
        assert!(is_bot_actor("bot2-x"));
        assert!(!is_bot_actor("owner-pc"));
        assert!(!is_bot_actor("robot-1"), "actor must start with bot, not merely contain it");
        assert!(!is_bot_actor("mom-iphone-1"));
    }

    #[test]
    fn attachment_rule_matches_relay_app() {
        assert!(is_attachment_client_id("file-v1-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2"));
        assert!(!is_attachment_client_id("file-v1-0F3C2A9B-1D2E-4F5A-8B6C-7D8E9FA0B1C2"));
        assert!(!is_attachment_client_id("file-v1-short"));
        assert!(!is_attachment_client_id("owner-pc-c1"));
        assert!(!is_attachment_client_id(""));
    }

    #[test]
    fn approval_reply_parsing() {
        assert_eq!(parse_approval_reply("승인 3"), Some((3, true)));
        assert_eq!(parse_approval_reply("  거절 #12 "), Some((12, false)));
        assert_eq!(parse_approval_reply("approve 1"), Some((1, true)));
        assert_eq!(parse_approval_reply("deny 7"), Some((7, false)));
        assert_eq!(parse_approval_reply("승인"), None);
        assert_eq!(parse_approval_reply("승인 abc"), None);
        assert_eq!(parse_approval_reply("승인 3 지금"), None);
        assert_eq!(parse_approval_reply("오늘 저녁 뭐 먹지"), None);
    }

    #[test]
    fn reply_bounds_cut_on_char_boundary() {
        let text = "가".repeat(100); // 300 bytes
        let cut = bounded_reply(&text, 64);
        assert!(cut.len() <= 64);
        assert!(cut.ends_with("…(길어서 줄임)"));
        assert_eq!(bounded_reply("짧다", 64), "짧다");
        assert_eq!(bounded("abc", 2), "ab");
    }

    /// A tiny stand-in worker speaking the FLEET-WORKER port: one approval,
    /// then a result that echoes the decision. P4 modes: a prompt `tool <json>`
    /// emits one `tool` frame (`tool_id` n1) built from the JSON (`tool2`: two
    /// frames, n1 and n2); the first `tool-result` it reads ends the turn with
    /// the frame echoed (sorted keys) in the result text. `askroom` asks a
    /// `mcp__steward__room_invite` approval carrying arguments. #474: `progress`
    /// emits interims before its result; `notify` emits notices after it.
    const FAKE_WORKER: &str = r#"
import json, sys
for line in sys.stdin:
    cmd = json.loads(line)
    if cmd["type"] == "turn":
        tid = cmd["turn_id"]
        print(json.dumps({"type": "session", "turn_id": tid, "session_id": "s1"}), flush=True)
        if cmd["prompt"].startswith("fail"):
            print(json.dumps({"type": "result", "turn_id": tid, "status": "uncertain", "reason": "runtime-error"}), flush=True)
            continue
        if cmd["prompt"].startswith("askroom"):
            print(json.dumps({"type": "approval", "turn_id": tid, "approval_id": "ap-2", "action": "mcp__steward__room_invite",
                              "description": "free text the worker made up",
                              "arguments": {"device": "jungin-iphone-1b89e3", "room": "family"}}), flush=True)
            continue
        if cmd["prompt"].startswith("ask"):
            print(json.dumps({"type": "approval", "turn_id": tid, "approval_id": "ap-1", "action": "bash", "description": "rm -rf /tmp/x"}), flush=True)
            continue
        if cmd["prompt"].startswith("tool"):
            word, spec = cmd["prompt"].split(" ", 1)
            spec = json.loads(spec)
            for i in range(2 if word == "tool2" else 1):
                frame = {"type": "tool", "turn_id": tid, "tool_id": "n%d" % (i + 1)}
                frame.update(spec)
                print(json.dumps(frame), flush=True)
            continue
        if cmd["prompt"].startswith("progress"):
            for i in range(3):
                print(json.dumps({"type": "interim", "turn_id": tid, "text": "step %d" % i}), flush=True)
            print(json.dumps({"type": "interim", "turn_id": "t-other", "text": "not this turn"}), flush=True)
            print(json.dumps({"type": "interim", "turn_id": tid, "text": "   "}), flush=True)
        print(json.dumps({"type": "result", "turn_id": tid, "status": "complete", "session_id": "s1", "text": "echo:" + cmd["prompt"] + "|" + cmd["sender"]}), flush=True)
        if cmd["prompt"].startswith("notify"):
            # After the result: no turn is active when these arrive.
            print(json.dumps({"type": "notice", "room": "soonwook", "text": "  reminder  "}), flush=True)
            print(json.dumps({"type": "notice", "room": "bad room!", "text": "x"}), flush=True)
            print(json.dumps({"type": "notice", "room": "soonwook", "text": " "}), flush=True)
            print(json.dumps({"type": "notice", "text": "no room"}), flush=True)
    elif cmd["type"] == "tool-result":
        print(json.dumps({"type": "result", "turn_id": cmd["turn_id"], "status": "complete", "session_id": "s1", "text": "tool:" + json.dumps(cmd, sort_keys=True)}), flush=True)
    elif cmd["type"] in ("approve", "deny"):
        allowed = cmd["type"] == "approve"
        print(json.dumps({"type": "approval-resolved", "turn_id": cmd["turn_id"], "approval_id": cmd["approval_id"], "allowed": allowed}), flush=True)
        print(json.dumps({"type": "result", "turn_id": cmd["turn_id"], "status": "complete", "session_id": "s1", "text": "did:" + str(allowed)}), flush=True)
"#;

    fn fake(config_tweak: impl FnOnce(&mut Config), state: Option<&Path>) -> Responder {
        let mut config = Config::new(Transport::Argv(vec!["python3".into(), "-c".into(), FAKE_WORKER.into()]), "owner".into());
        config_tweak(&mut config);
        Responder::spawn(config, state).unwrap_or_else(|e| panic!("spawn: {e}"))
    }

    fn pump_until(r: &mut Responder, want: usize) -> Vec<Outbound> {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut got = Vec::new();
        while got.len() < want && Instant::now() < deadline {
            got.extend(r.pump().unwrap_or_else(|e| panic!("pump: {e}")));
            std::thread::sleep(Duration::from_millis(20));
        }
        got
    }

    fn inbound(seq: i64, device: &str, text: &str) -> Inbound {
        Inbound { seq, sender_device: device.into(), text: text.into() }
    }

    #[test]
    fn turn_round_trip_and_queue_order() {
        let mut r = fake(|_| {}, None);
        assert_eq!(r.offer(inbound(10, "owner-pc", "hello")).unwrap(), Offer::Started);
        assert_eq!(r.offer(inbound(11, "mom-iphone-1", "second")).unwrap(), Offer::Queued { depth: 1 });
        let got = pump_until(&mut r, 2);
        assert_eq!(got[0], Outbound::Reply { seq: 10, text: "echo:hello|@owner-pc:hande".into() });
        assert_eq!(got[1], Outbound::Reply { seq: 11, text: "echo:second|@mom-iphone-1:hande".into() });
        assert!(r.active.is_none());
    }

    #[test]
    fn interims_precede_the_reply_and_are_capped_per_turn() {
        let mut r = fake(|_| {}, None);
        assert_eq!(r.offer(inbound(5, "owner-pc", "progress")).unwrap(), Offer::Started);
        let got = pump_until(&mut r, 4);
        assert_eq!(got, vec![
            Outbound::Interim { seq: 5, text: "step 0".into() },
            Outbound::Interim { seq: 5, text: "step 1".into() },
            Outbound::Interim { seq: 5, text: "step 2".into() },
            Outbound::Reply { seq: 5, text: "echo:progress|@owner-pc:hande".into() },
        ], "another turn's interim and a blank one are not posted");
        assert!(r.active.is_none());

        let mut r = fake(|c| c.interim_max = 2, None);
        r.offer(inbound(6, "owner-pc", "progress")).unwrap();
        assert_eq!(r.offer(inbound(7, "owner-pc", "progress again")).unwrap(), Offer::Queued { depth: 1 });
        let got = pump_until(&mut r, 6);
        assert_eq!(got, vec![
            Outbound::Interim { seq: 6, text: "step 0".into() },
            Outbound::Interim { seq: 6, text: "step 1".into() },
            Outbound::Reply { seq: 6, text: "echo:progress|@owner-pc:hande".into() },
            Outbound::Interim { seq: 7, text: "step 0".into() },
            Outbound::Interim { seq: 7, text: "step 1".into() },
            Outbound::Reply { seq: 7, text: "echo:progress again|@owner-pc:hande".into() },
        ], "the cap counts per turn");

        let mut r = fake(|c| c.interim_max = 0, None);
        r.offer(inbound(8, "owner-pc", "progress")).unwrap();
        assert_eq!(pump_until(&mut r, 1), vec![Outbound::Reply { seq: 8, text: "echo:progress|@owner-pc:hande".into() }]);
    }

    #[test]
    fn notice_needs_no_active_turn_but_a_room_and_text() {
        let mut r = fake(|_| {}, None);
        r.offer(inbound(9, "owner-pc", "notify")).unwrap();
        let mut got = pump_until(&mut r, 2);
        std::thread::sleep(Duration::from_millis(300));
        got.extend(r.pump().unwrap());
        assert_eq!(got, vec![
            Outbound::Reply { seq: 9, text: "echo:notify|@owner-pc:hande".into() },
            Outbound::Notice { room: "soonwook".into(), text: "reminder".into() },
        ], "a bad room, a blank text and a missing room are not posted");
        assert!(r.active.is_none());
        assert!(is_room_id("family-acc") && !is_room_id("") && !is_room_id(&"a".repeat(65)) && !is_room_id("방"));
    }

    #[test]
    fn queue_cap_drops_the_newest() {
        let mut r = fake(|c| c.queue_max = 1, None);
        // Hold the worker on an approval so the queue fills.
        assert_eq!(r.offer(inbound(1, "owner-pc", "ask me")).unwrap(), Offer::Started);
        assert_eq!(r.offer(inbound(2, "owner-pc", "a")).unwrap(), Offer::Queued { depth: 1 });
        assert_eq!(r.offer(inbound(3, "owner-pc", "b")).unwrap(), Offer::Dropped { reason: "queue_full" });
    }

    #[test]
    fn approval_round_trip_owner_decides() {
        let mut r = fake(|_| {}, None);
        r.offer(inbound(5, "owner-pc", "ask: delete")).unwrap();
        let got = pump_until(&mut r, 1);
        match &got[0] {
            Outbound::ApprovalRequest { n, seq, text } => {
                assert_eq!((*n, *seq), (1, 5));
                assert!(text.contains("승인 필요 #1"), "{text}");
                assert!(text.contains("rm -rf /tmp/x"));
                assert!(text.contains("승인 1"));
            }
            other => panic!("expected approval request, got {other:?}"),
        }
        assert_eq!(r.resolve(9, true), None, "unknown number is ignored");
        assert_eq!(r.resolve(1, false), Some(false));
        let got = pump_until(&mut r, 2);
        assert_eq!(got[0], Outbound::ApprovalResolved { n: 1, allowed: false });
        assert_eq!(got[1], Outbound::Reply { seq: 5, text: "did:False".into() });
        assert!(r.approvals.is_empty());
    }

    #[test]
    fn uncertain_result_retires_the_worker_and_drains_the_queue() {
        let mut r = fake(|_| {}, None);
        r.offer(inbound(1, "owner-pc", "fail now")).unwrap();
        r.offer(inbound(2, "owner-pc", "later")).unwrap();
        let got = pump_until(&mut r, 3);
        assert_eq!(got[0], Outbound::Uncertain { seq: 1, reason: "runtime-error".into() });
        assert_eq!(got[1], Outbound::Uncertain { seq: 2, reason: "worker_gone".into() });
        assert!(matches!(got[2], Outbound::WorkerGone { .. }));
        assert!(r.is_gone());
        assert_eq!(r.offer(inbound(3, "owner-pc", "x")).unwrap(), Offer::Dropped { reason: "worker_gone" });
    }

    #[test]
    fn inbox_marks_active_turn_and_a_restart_reports_it_uncertain_once() {
        let dir = std::env::temp_dir().join(format!("bot-responder-{}-{}", std::process::id(), now_secs()));
        std::fs::create_dir_all(&dir).unwrap();
        let state = dir.join("bot.state");
        {
            let mut r = fake(|_| {}, Some(&state));
            r.offer(inbound(42, "owner-pc", "ask: hold")).unwrap();   // stays active (waiting for approval)
            let _ = pump_until(&mut r, 1);
            let raw = std::fs::read(inbox_path(&state)).unwrap();
            let inbox: Inbox = serde_json::from_slice(&raw).unwrap();
            assert_eq!(inbox.active.as_ref().map(|a| a.seq), Some(42));
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                assert_eq!(std::fs::metadata(inbox_path(&state)).unwrap().permissions().mode() & 0o777, 0o600);
            }
        }
        // "Restart": a new responder over the same state file.
        let mut r = fake(|_| {}, Some(&state));
        let got = r.pump().unwrap();
        assert_eq!(got, vec![Outbound::Uncertain { seq: 42, reason: "restart".into() }]);
        let inbox: Inbox = serde_json::from_slice(&std::fs::read(inbox_path(&state)).unwrap()).unwrap();
        assert!(inbox.active.is_none(), "cleared, never re-run");
        assert!(r.pump().unwrap().is_empty(), "reported once");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `Transport::Unix`: the same port over a socket a service manager would
    /// own. A python listener plays systemd `Accept=yes` + `StandardInput=socket`.
    #[test]
    fn unix_socket_transport_round_trips() {
        let dir = std::env::temp_dir().join(format!("bot-responder-sock-{}-{}", std::process::id(), now_secs()));
        std::fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("responder.sock");
        let server = format!(r#"
import json, socket, os
s = socket.socket(socket.AF_UNIX); s.bind({sock:?}); s.listen(1)
print("listening", flush=True)
c, _ = s.accept()
f = c.makefile("rwb")
for line in f:
    cmd = json.loads(line)
    if cmd["type"] == "turn":
        f.write((json.dumps({{"type": "result", "turn_id": cmd["turn_id"], "status": "complete", "session_id": "s", "text": "sock:" + cmd["prompt"]}}) + "\n").encode()); f.flush()
"#, sock = sock.to_string_lossy());
        let mut listener = Command::new("python3").arg("-c").arg(&server).stdout(Stdio::piped()).spawn().unwrap();
        {
            let mut line = String::new();
            BufReader::new(listener.stdout.take().unwrap()).read_line(&mut line).unwrap();
            assert_eq!(line.trim(), "listening");
        }
        let config = Config::new(Transport::Unix(sock.clone()), "owner".into());
        let mut r = Responder::spawn(config, None).unwrap_or_else(|e| panic!("connect: {e}"));
        assert!(r.child.is_none());
        r.offer(inbound(3, "owner-pc", "ping")).unwrap();
        let got = pump_until(&mut r, 1);
        assert_eq!(got, vec![Outbound::Reply { seq: 3, text: "sock:ping".into() }]);
        drop(r);
        let _ = listener.kill();
        let _ = listener.wait();
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- P4 tools ----

    fn tool_prompt(name: &str, arguments: serde_json::Value) -> String {
        format!("tool {}", serde_json::json!({ "name": name, "arguments": arguments }))
    }

    /// The `tool-result` frame the fake worker echoed back in its result text.
    fn echoed_tool_result(item: &Outbound) -> serde_json::Value {
        match item {
            Outbound::Reply { text, .. } => {
                let raw = text.strip_prefix("tool:").unwrap_or_else(|| panic!("not a tool echo: {text}"));
                serde_json::from_str(raw).unwrap()
            }
            other => panic!("expected the worker's result, got {other:?}"),
        }
    }

    #[test]
    fn tool_command_mapping_and_validation() {
        assert_eq!(
            tool_command("room_invite", Some(&serde_json::json!({"room": "family", "device": "jungin-iphone-1b89e3"}))),
            Some(("invite".into(), "family".into(), "jungin-iphone-1b89e3".into()))
        );
        assert_eq!(
            tool_command("room_remove", Some(&serde_json::json!({"room": "family", "device": "x-1"}))),
            Some(("remove".into(), "family".into(), "x-1".into()))
        );
        assert_eq!(tool_command("room_join", Some(&serde_json::json!({"room": "r2"}))), Some(("join".into(), "r2".into(), String::new())));
        assert_eq!(tool_command("room_members", Some(&serde_json::json!({"room": "r2"}))), Some(("members".into(), "r2".into(), String::new())));
        assert_eq!(tool_command("room_close", Some(&serde_json::json!({"room": "r2"}))), Some(("close".into(), "r2".into(), String::new())));
        assert_eq!(tool_command("room_close", Some(&serde_json::json!({"room": "r2", "device": "x"}))), None, "close takes the room only");
        assert_eq!(tool_command("room_mode", Some(&serde_json::json!({"room": "r2", "mode": "agent"}))), Some(("mode".into(), "r2".into(), "agent".into())));
        assert_eq!(tool_command("room_create", Some(&serde_json::json!({"room": "r3"}))), Some(("create".into(), "r3".into(), "silent".into())), "mode defaults to silent");
        assert_eq!(tool_command("room_create", Some(&serde_json::json!({"room": "r3", "mode": "agent"}))), Some(("create".into(), "r3".into(), "agent".into())));
        assert_eq!(tool_command("room_status", Some(&serde_json::json!({}))), Some(("status".into(), "-".into(), String::new())));
        assert_eq!(tool_command("room_status", None), Some(("status".into(), "-".into(), String::new())), "missing arguments = {{}}");
        // Rejections.
        assert_eq!(tool_command("room_invite", Some(&serde_json::json!({"room": "family"}))), None, "device required");
        assert_eq!(tool_command("room_invite", Some(&serde_json::json!({"room": "family", "device": "a b"}))), None, "identifier shape");
        assert_eq!(tool_command("room_invite", Some(&serde_json::json!({"room": "family", "device": 7}))), None, "strings only");
        assert_eq!(tool_command("room_mode", Some(&serde_json::json!({"room": "r", "mode": "loud"}))), None);
        assert_eq!(tool_command("room_create", Some(&serde_json::json!({"room": "r", "mode": "loud"}))), None);
        assert_eq!(tool_command("room_status", Some(&serde_json::json!({"room": "r"}))), None, "no extra keys");
        assert_eq!(tool_command("room_join", Some(&serde_json::json!(["r"]))), None, "arguments must be an object");
        assert_eq!(tool_command("room_destroy", Some(&serde_json::json!({"room": "r"}))), None);
        assert_eq!(tool_command("", None), None);
        assert!(is_tool_id("n1") && is_tool_id(&"a".repeat(128)));
        assert!(!is_tool_id("") && !is_tool_id(&"a".repeat(129)) && !is_tool_id("n 1") && !is_tool_id("n/1"));
    }

    #[test]
    fn tool_call_from_owner_runs_and_result_reaches_the_worker() {
        let mut r = fake(|_| {}, None);
        r.offer(inbound(20, "owner-pc", &tool_prompt("room_invite", serde_json::json!({"room": "family", "device": "jungin-iphone-1b89e3"})))).unwrap();
        let got = pump_until(&mut r, 1);
        assert_eq!(
            got[0],
            Outbound::ToolCall { tool_id: "n1".into(), name: "room_invite".into(), op: "invite".into(), room: "family".into(), arg: "jungin-iphone-1b89e3".into() }
        );
        assert_eq!(r.pending_tool.as_deref(), Some("n1"));
        // A wrong id is dropped: the worker would have ended the turn on it.
        r.tool_result("zzz", Err("nope".into()));
        assert_eq!(r.pending_tool.as_deref(), Some("n1"));
        r.tool_result("n1", Ok(serde_json::json!({ "op": "invite", "room": "family", "seq": 9, "ok": true })));
        assert!(r.pending_tool.is_none());
        let got = pump_until(&mut r, 1);
        let frame = echoed_tool_result(&got[0]);
        assert_eq!(frame["type"], "tool-result");
        assert_eq!(frame["turn_id"], "t-20");
        assert_eq!(frame["tool_id"], "n1");
        assert_eq!(frame["ok"], true);
        assert_eq!(frame["result"]["seq"], 9);
        assert_eq!(frame["result"]["ok"], true);
        assert!(frame.get("error").is_none());
        assert!(r.active.is_none());
        // A second turn is independent: the error path formats `error`.
        r.offer(inbound(21, "owner-pc", &tool_prompt("room_status", serde_json::json!({})))).unwrap();
        let got = pump_until(&mut r, 1);
        assert!(matches!(&got[0], Outbound::ToolCall { op, room, arg, .. } if op == "status" && room == "-" && arg.is_empty()), "{got:?}");
        r.tool_result("n1", Err("steward_only".into()));
        let frame = echoed_tool_result(&pump_until(&mut r, 1)[0]);
        assert_eq!((frame["ok"].as_bool(), frame["error"].as_str(), frame["turn_id"].as_str()), (Some(false), Some("steward_only"), Some("t-21")));
    }

    #[test]
    fn tool_call_from_non_owner_is_refused_without_executing() {
        let mut r = fake(|_| {}, None);
        r.offer(inbound(30, "mom-iphone-1", &tool_prompt("room_invite", serde_json::json!({"room": "family", "device": "jungin-iphone-1b89e3"})))).unwrap();
        let got = pump_until(&mut r, 1);
        assert!(!got.iter().any(|o| matches!(o, Outbound::ToolCall { .. })), "{got:?}");
        let frame = echoed_tool_result(&got[0]);
        assert_eq!((frame["ok"].as_bool(), frame["error"].as_str(), frame["tool_id"].as_str()), (Some(false), Some("owner_only"), Some("n1")));
        assert!(r.pending_tool.is_none());
    }

    #[test]
    fn tool_call_with_bad_arguments_is_refused() {
        let mut r = fake(|_| {}, None);
        r.offer(inbound(31, "owner-pc", &tool_prompt("room_invite", serde_json::json!({"room": "family"})))).unwrap();
        let got = pump_until(&mut r, 1);
        assert!(!got.iter().any(|o| matches!(o, Outbound::ToolCall { .. })), "{got:?}");
        let frame = echoed_tool_result(&got[0]);
        assert_eq!((frame["ok"].as_bool(), frame["error"].as_str()), (Some(false), Some("bad_arguments")));
        // Unknown tool name, same answer — even from the owner.
        r.offer(inbound(32, "owner-pc", &tool_prompt("room_destroy", serde_json::json!({"room": "family"})))).unwrap();
        let frame = echoed_tool_result(&pump_until(&mut r, 1)[0]);
        assert_eq!(frame["error"], "bad_arguments");
    }

    #[test]
    fn second_tool_call_while_one_is_pending_is_busy() {
        let mut r = fake(|_| {}, None);
        r.offer(inbound(33, "owner-pc", &format!("tool2 {}", serde_json::json!({ "name": "room_members", "arguments": {"room": "family"} })))).unwrap();
        // n1 becomes the call; n2 is answered `busy` at once, which ends the fake worker's turn.
        let got = pump_until(&mut r, 2);
        assert!(matches!(&got[0], Outbound::ToolCall { tool_id, op, .. } if tool_id == "n1" && op == "members"), "{got:?}");
        let frame = echoed_tool_result(&got[1]);
        assert_eq!((frame["tool_id"].as_str(), frame["error"].as_str()), (Some("n2"), Some("busy")));
        assert!(r.pending_tool.is_none(), "the turn ended; the late n1 answer is dropped");
        assert!(r.active.is_none());
    }

    #[test]
    fn steward_tool_approval_shows_name_and_arguments() {
        let mut r = fake(|_| {}, None);
        r.offer(inbound(40, "owner-pc", "askroom please")).unwrap();
        let got = pump_until(&mut r, 1);
        match &got[0] {
            Outbound::ApprovalRequest { n, seq, text } => {
                assert_eq!((*n, *seq), (1, 40));
                assert_eq!(
                    text,
                    "⚠️ 승인 필요 #1: 방 명령 room_invite · device=jungin-iphone-1b89e3 · room=family\n답장: 「승인 1」 또는 「거절 1」 (owner 만)"
                );
                assert!(!text.contains("free text"), "the worker's description is not shown for steward tools");
            }
            other => panic!("expected approval request, got {other:?}"),
        }
        // Pure rendering: non-steward actions are unchanged; values are bounded.
        assert_eq!(steward_tool_summary("room_status", None), "방 명령 room_status");
        assert_eq!(steward_tool_summary("room_mode", Some(&serde_json::json!({"mode": "agent", "room": "r", "n": 3}))), "방 명령 room_mode · mode=agent · n=3 · room=r");
        let long = steward_tool_summary("room_join", Some(&serde_json::json!({"room": "x".repeat(200)})));
        assert!(long.len() < 120, "{long}");
    }

    #[test]
    fn inbox_without_sender_device_still_loads() {
        let inbox: Inbox = serde_json::from_str(r#"{"version":1,"active":{"seq":4,"turn_id":"t-4","started_at":1}}"#).unwrap();
        let active = inbox.active.unwrap();
        assert_eq!((active.seq, active.turn_id.as_str(), active.sender_device.as_str()), (4, "t-4", ""));
    }

    #[test]
    fn watchdog_marks_a_silent_turn_uncertain() {
        let mut r = fake(|c| c.turn_secs = 0, None);
        r.offer(inbound(7, "owner-pc", "ask: never answered")).unwrap();
        std::thread::sleep(Duration::from_millis(50));
        let got = pump_until(&mut r, 2);
        assert!(got.iter().any(|o| *o == Outbound::Uncertain { seq: 7, reason: "watchdog".into() }), "{got:?}");
        assert!(r.active.is_none());
    }
}
