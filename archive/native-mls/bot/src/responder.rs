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

use crate::api::BotError;
use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader, Write};
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
/// Largest `text` field the bot sends to the worker (fleet_core MAX_TEXT_BYTES
/// is 16 KiB; the header the worker prepends needs a little room).
const PROMPT_MAX_BYTES: usize = 15 * 1024;

#[derive(Clone, Debug)]
pub struct Config {
    /// Child process argv (`[python3, fleet_worker.py, --workdir, …]`). No shell.
    pub argv: Vec<String>,
    /// Actor whose text replies resolve approvals (`owner`).
    pub owner_actor: String,
    pub reply_max_bytes: usize,
    pub queue_max: usize,
    pub turn_secs: u64,
}

impl Config {
    pub fn new(argv: Vec<String>, owner_actor: String) -> Self {
        Config {
            argv,
            owner_actor,
            reply_max_bytes: DEFAULT_REPLY_MAX_BYTES,
            queue_max: DEFAULT_QUEUE_MAX,
            turn_secs: DEFAULT_TURN_SECS,
        }
    }
}

/// What the poll loop must say in the room (it encrypts and POSTs; this
/// module never touches MLS).
#[derive(Debug, PartialEq, Eq)]
pub enum Outbound {
    /// The worker's answer for the turn started by relay seq `seq`.
    Reply { seq: i64, text: String },
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
}

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
}

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct Inbox {
    version: u32,
    active: Option<ActiveTurn>,
}

const INBOX_VERSION: u32 = 1;

pub struct Responder {
    config: Config,
    child: Child,
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
}

impl Responder {
    /// Spawn the worker. `state_file` (the bot's `--state-file`) locates the
    /// inbox next to it; without one the duplicate guard is memory-only.
    pub fn spawn(config: Config, state_file: Option<&Path>) -> Result<Self, BotError> {
        let (program, args) = config.argv.split_first().ok_or(BotError::Local("responder argv empty"))?;
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|_| BotError::Local("responder spawn failed"))?;
        let mut stdin = child.stdin.take().ok_or(BotError::Local("responder stdin"))?;
        let stdout = child.stdout.take().ok_or(BotError::Local("responder stdout"))?;
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
        let active = ActiveTurn { seq: inbound.seq, turn_id: turn_id.clone(), started_at: now_secs() };
        // Durable before the child sees it (FLEET-WORKER: the parent inbox is
        // the duplicate guard, not the port).
        self.write_inbox(Some(&active))?;
        self.active = Some((active, Instant::now()));
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
                let summary = if description.is_empty() { action } else { description };
                let text = format!(
                    "⚠️ 승인 필요 #{n}: {}\n답장: 「승인 {n}」 또는 「거절 {n}」 ({} 만)",
                    bounded(summary, 2048),
                    self.config.owner_actor
                );
                out.push(Outbound::ApprovalRequest { n, seq, text });
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

    fn finish_active(&mut self) -> Result<(), BotError> {
        self.active = None;
        self.approvals.clear();
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
        let _ = self.child.kill();
        let _ = self.child.wait();
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
    /// then a result that echoes the decision.
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
        if cmd["prompt"].startswith("ask"):
            print(json.dumps({"type": "approval", "turn_id": tid, "approval_id": "ap-1", "action": "bash", "description": "rm -rf /tmp/x"}), flush=True)
            continue
        print(json.dumps({"type": "result", "turn_id": tid, "status": "complete", "session_id": "s1", "text": "echo:" + cmd["prompt"] + "|" + cmd["sender"]}), flush=True)
    elif cmd["type"] in ("approve", "deny"):
        allowed = cmd["type"] == "approve"
        print(json.dumps({"type": "approval-resolved", "turn_id": cmd["turn_id"], "approval_id": cmd["approval_id"], "allowed": allowed}), flush=True)
        print(json.dumps({"type": "result", "turn_id": cmd["turn_id"], "status": "complete", "session_id": "s1", "text": "did:" + str(allowed)}), flush=True)
"#;

    fn fake(config_tweak: impl FnOnce(&mut Config), state: Option<&Path>) -> Responder {
        let mut config = Config::new(vec!["python3".into(), "-c".into(), FAKE_WORKER.into()], "owner".into());
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
