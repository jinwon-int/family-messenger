//! The responder state machine (#396): everything `scripts/fleet_worker.py`'s
//! `Worker` decided, without any I/O. Inputs are parent frames (the bot or
//! `fleet_matrix.py`, protocol `docs/FLEET-WORKER.md`), adapter frames (the
//! Python ccc-node boundary, `scripts/ccc_adapter.py`) and the clock; outputs
//! are frames for either side. `main.rs` does the reading and writing.
//!
//! Lifecycle of one process (same as fleet_worker):
//!   Idle ──turn──▶ Running ──result complete──▶ Idle
//!   Running ──cancel / timeout / runtime error / EOF──▶ Stopping
//!     (interrupt → close the runtime → one `result uncertain`) ──▶ Done
//! A worker that reported `uncertain` never takes another turn: the adapter
//! cannot prove the old execution stopped (Codex has no turn id while
//! awaiting turn/start), so the process retires (exit 1) and the parent's
//! next connection gets a fresh one.

use crate::harness::steward_tool;
use crate::wire::{
    bounded_str, bounded_text, is_sender, is_tool_arg, is_turn_id, parse_frame, py_dumps, MAX_APPROVAL_FRAME,
    MAX_INPUT_FRAME, MAX_REPLY_BYTES, MAX_TEXT_BYTES,
};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::time::{Duration, Instant};

/// The adapter waits 5 s on `session.interrupt()`; this covers its answer.
pub const INTERRUPT_GRACE: Duration = Duration::from_secs(6);
/// The adapter waits 10 s on `runtime.close()`; no answer = not closed.
pub const CLOSE_GRACE: Duration = Duration::from_secs(11);

#[derive(Clone, Debug, PartialEq)]
pub enum Out {
    /// A frame for the parent (bot / fleet_matrix).
    Parent(Value),
    /// A frame for the Python adapter.
    Adapter(Value),
}

#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub turn: Duration,
    pub approval: Duration,
    pub tool: Duration,
}

struct Approval {
    request_id: Value,
    deadline: Instant,
}

struct PendingTool {
    tool_id: String,
    request_id: Value,
    deadline: Instant,
}

struct Turn {
    id: String,
    deadline: Instant,
    text: String,
    terminal: bool,
    approvals: HashMap<String, Approval>,
    tool: Option<PendingTool>,
}

enum Phase {
    Idle,
    Running(Turn),
    /// Tearing down an uncertain turn: `interrupt` sent, then `close`.
    Stopping { turn_id: String, reason: &'static str, closing: bool, deadline: Instant },
    /// Idle shutdown (parent EOF / bad frame): `close` sent.
    Closing { deadline: Instant },
    Done,
}

pub struct Machine {
    limits: Limits,
    phase: Phase,
    exit_code: u8,
    nonce: Box<dyn FnMut() -> String>,
    out: Vec<Out>,
}

impl Machine {
    pub fn new(limits: Limits, nonce: Box<dyn FnMut() -> String>) -> Self {
        Machine { limits, phase: Phase::Idle, exit_code: 0, nonce, out: Vec::new() }
    }

    /// Frames produced since the last call, in order.
    pub fn take(&mut self) -> Vec<Out> {
        std::mem::take(&mut self.out)
    }

    /// `Some(exit code)` once the process should exit.
    pub fn done(&self) -> Option<u8> {
        matches!(self.phase, Phase::Done).then_some(self.exit_code)
    }

    pub fn next_deadline(&self) -> Option<Instant> {
        match &self.phase {
            Phase::Running(t) => {
                let mut d = t.deadline;
                for a in t.approvals.values() {
                    d = d.min(a.deadline);
                }
                if let Some(tool) = &t.tool {
                    d = d.min(tool.deadline);
                }
                Some(d)
            }
            Phase::Stopping { deadline, .. } | Phase::Closing { deadline } => Some(*deadline),
            Phase::Idle | Phase::Done => None,
        }
    }

    fn parent(&mut self, frame: Value) {
        self.out.push(Out::Parent(frame));
    }

    fn adapter(&mut self, frame: Value) {
        self.out.push(Out::Adapter(frame));
    }

    // ── parent side ─────────────────────────────────────────────────────

    /// One inbound line (newline optional).
    pub fn parent_line(&mut self, line: &[u8], now: Instant) {
        if !matches!(self.phase, Phase::Idle | Phase::Running(_)) {
            // fleet_worker: a closed worker raises on input; the process exits
            // non-zero after the cleanup already under way. Never a 2nd result.
            self.exit_code = 1;
            return;
        }
        if line.len() > MAX_INPUT_FRAME {
            return self.fatal(now);
        }
        match parse_frame(line) {
            Ok(command) => self.handle(command, now),
            Err(()) => self.fatal(now),
        }
    }

    /// Malformed / oversized input or an unreadable stream: stop (exit 1).
    pub fn fatal(&mut self, now: Instant) {
        self.exit_code = 1;
        self.shutdown(now);
    }

    /// Parent closed its end: stop running work, close the runtime, exit.
    pub fn parent_eof(&mut self, now: Instant) {
        self.shutdown(now);
    }

    /// The parent stopped reading (5 s write stall or a write error).
    pub fn output_failed(&mut self, now: Instant) {
        self.exit_code = 1;
        if matches!(self.phase, Phase::Running(_)) {
            self.teardown("runtime-error", false, now);
        } else {
            self.shutdown(now);
        }
    }

    fn shutdown(&mut self, now: Instant) {
        match self.phase {
            Phase::Idle => {
                self.adapter(json!({"type": "close"}));
                self.phase = Phase::Closing { deadline: now + CLOSE_GRACE };
            }
            Phase::Running(_) => self.teardown("cancelled", false, now),
            _ => {}
        }
    }

    fn handle(&mut self, command: Value, now: Instant) {
        let Some(obj) = command.as_object() else {
            return self.parent(json!({"type": "rejected", "reason": "invalid-command"}));
        };
        let turn_id = match obj.get("turn_id").and_then(Value::as_str) {
            Some(t) if is_turn_id(t) => t.to_string(),
            _ => return self.parent(json!({"type": "rejected", "reason": "invalid-turn-id"})),
        };
        match obj.get("type").and_then(Value::as_str) {
            Some("turn") => self.turn(obj, turn_id, now),
            Some(kind @ ("approve" | "deny")) => {
                let allow = kind == "approve";
                let approval_id = obj.get("approval_id").and_then(Value::as_str).map(str::to_string);
                let found = match (&mut self.phase, &approval_id) {
                    (Phase::Running(t), Some(id)) if t.id == turn_id => t.approvals.remove(id),
                    _ => None,
                };
                self.parent(json!({"type": "control", "turn_id": turn_id, "accepted": found.is_some()}));
                if let (Some(approval), Some(id)) = (found, approval_id) {
                    self.adapter(json!({"type": "approval-decision", "request_id": approval.request_id, "allow": allow}));
                    self.parent(json!({"type": "approval-resolved", "turn_id": turn_id, "approval_id": id, "allowed": allow}));
                }
            }
            Some("tool-result") => {
                let tool_id = obj.get("tool_id").and_then(Value::as_str);
                let found = match (&mut self.phase, tool_id) {
                    (Phase::Running(t), Some(id)) if t.id == turn_id && t.tool.as_ref().map(|p| p.tool_id == id) == Some(true) => {
                        t.tool.take()
                    }
                    _ => None,
                };
                if let Some(tool) = &found {
                    let outcome = if obj.get("ok") == Some(&Value::Bool(true)) {
                        json!({"ok": true, "result": obj.get("result").cloned().unwrap_or(Value::Null)})
                    } else {
                        let error = match obj.get("error").and_then(Value::as_str) {
                            Some(e) if !e.is_empty() => e.to_string(),
                            _ => "steward_error".to_string(),
                        };
                        json!({"ok": false, "error": error})
                    };
                    self.adapter(tool_result_frame(&tool.request_id, &outcome));
                }
                self.parent(json!({"type": "control", "turn_id": turn_id, "accepted": found.is_some()}));
            }
            Some("cancel") => {
                let matched = matches!(&self.phase, Phase::Running(t) if t.id == turn_id);
                self.parent(json!({"type": "control", "turn_id": turn_id, "accepted": matched}));
                if matched {
                    self.exit_code = 1;
                    self.teardown("cancelled", true, now);
                }
            }
            _ => self.parent(json!({"type": "rejected", "turn_id": turn_id, "reason": "unknown-command"})),
        }
    }

    fn turn(&mut self, obj: &Map<String, Value>, turn_id: String, now: Instant) {
        if !matches!(self.phase, Phase::Idle) {
            return self.parent(json!({"type": "rejected", "turn_id": turn_id, "reason": "busy"}));
        }
        let present = |key: &str| obj.get(key).filter(|v| !v.is_null());
        let prompt = obj.get("prompt").and_then(|p| bounded_text(p, MAX_TEXT_BYTES));
        let session_ok = present("session_id").map(|s| bounded_text(s, 255).is_some()).unwrap_or(true);
        let sender = present("sender");
        let sender_ok = sender.map(|s| s.as_str().map(is_sender).unwrap_or(false)).unwrap_or(true);
        let room_kind = present("room_kind");
        let room_ok = room_kind.map(|k| matches!(k.as_str(), Some("direct" | "family"))).unwrap_or(true);
        let Some(body) = prompt.filter(|_| session_ok && sender_ok && room_ok) else {
            return self.parent(json!({"type": "rejected", "turn_id": turn_id, "reason": "invalid-turn"}));
        };
        let prompt = compose_prompt(body, sender.and_then(Value::as_str), room_kind.and_then(Value::as_str));
        let session_id = present("session_id").cloned().unwrap_or(Value::Null);
        self.adapter(json!({"type": "turn", "prompt": prompt, "session_id": session_id}));
        self.phase = Phase::Running(Turn {
            id: turn_id,
            deadline: now + self.limits.turn,
            text: String::new(),
            terminal: false,
            approvals: HashMap::new(),
            tool: None,
        });
    }

    /// End the running turn as uncertain. `resolve` (explicit cancel) tells the
    /// parent each open approval closed as denied, as fleet_worker's cancel did.
    fn teardown(&mut self, reason: &'static str, resolve: bool, now: Instant) {
        if !matches!(self.phase, Phase::Running(_)) {
            return;
        }
        let Phase::Running(turn) = std::mem::replace(&mut self.phase, Phase::Done) else { unreachable!() };
        if reason != "cancelled" || resolve {
            self.exit_code = 1;
        }
        for (approval_id, approval) in turn.approvals {
            self.adapter(json!({"type": "approval-decision", "request_id": approval.request_id, "allow": false}));
            if resolve {
                self.parent(json!({"type": "approval-resolved", "turn_id": turn.id, "approval_id": approval_id, "allowed": false}));
            }
        }
        if let Some(tool) = turn.tool {
            self.adapter(tool_result_frame(&tool.request_id, &json!({"ok": false, "error": "cancelled"})));
        }
        self.adapter(json!({"type": "interrupt"}));
        self.phase = Phase::Stopping { turn_id: turn.id, reason, closing: false, deadline: now + INTERRUPT_GRACE };
    }

    fn finish(&mut self, runtime_closed: bool) {
        if !runtime_closed {
            self.exit_code = 1;
        }
        if let Phase::Stopping { turn_id, reason, .. } = std::mem::replace(&mut self.phase, Phase::Done) {
            self.parent(json!({"type": "result", "turn_id": turn_id, "status": "uncertain",
                               "reason": reason, "runtime_closed": runtime_closed}));
        }
    }

    // ── adapter side ────────────────────────────────────────────────────

    pub fn adapter_frame(&mut self, frame: Value, now: Instant) {
        let kind = frame.get("type").and_then(Value::as_str).unwrap_or("").to_string();
        match kind.as_str() {
            "approval-request" => return self.approval_request(&frame, now),
            "tool-call" => return self.tool_call(&frame, now),
            _ => {}
        }
        match &mut self.phase {
            Phase::Running(t) => match kind.as_str() {
                "session" => {
                    let id = t.id.clone();
                    let session_id = frame.get("session_id").cloned().unwrap_or(Value::Null);
                    self.parent(json!({"type": "session", "turn_id": id, "session_id": session_id}));
                }
                "text" => match frame.get("text").and_then(Value::as_str) {
                    Some(text) => {
                        t.text.push_str(text);
                        if t.text.len() > MAX_REPLY_BYTES {
                            self.teardown("runtime-error", false, now);
                        }
                    }
                    None => self.adapter_lost(),
                },
                "completion" => {
                    if frame.get("stop_reason").and_then(Value::as_str) == Some("end_turn") {
                        t.terminal = true;
                    } else {
                        self.teardown("runtime-error", false, now);
                    }
                }
                "error" | "turn-failed" => self.teardown("runtime-error", false, now),
                "turn-end" => {
                    if !t.terminal || !bounded_str(&t.text, MAX_REPLY_BYTES) {
                        return self.teardown("runtime-error", false, now);
                    }
                    let (id, text) = (t.id.clone(), std::mem::take(&mut t.text));
                    let session_id = frame.get("session_id").cloned().unwrap_or(Value::Null);
                    self.phase = Phase::Idle;
                    self.parent(json!({"type": "result", "turn_id": id, "status": "complete",
                                       "session_id": session_id, "text": text}));
                }
                _ => {}
            },
            Phase::Stopping { closing, deadline, .. } => match kind.as_str() {
                "interrupted" if !*closing => {
                    *closing = true;
                    *deadline = now + CLOSE_GRACE;
                    self.adapter(json!({"type": "close"}));
                }
                "closed" if *closing => {
                    let ok = frame.get("ok") == Some(&Value::Bool(true));
                    self.finish(ok);
                }
                // Late turn events from the execution being torn down.
                _ => {}
            },
            Phase::Closing { .. } if kind == "closed" => {
                // fleet_worker re-raised a failed runtime.close(): exit 1, and
                // fleet_matrix only confirms a `complete` result on exit 0.
                if frame.get("ok") != Some(&Value::Bool(true)) {
                    self.exit_code = 1;
                }
                self.phase = Phase::Done;
            }
            _ => {}
        }
    }

    /// The adapter died, closed its stdout, or broke the protocol.
    pub fn adapter_lost(&mut self) {
        match std::mem::replace(&mut self.phase, Phase::Done) {
            Phase::Running(t) => {
                self.exit_code = 1;
                self.parent(json!({"type": "result", "turn_id": t.id, "status": "uncertain",
                                   "reason": "runtime-error", "runtime_closed": false}));
            }
            Phase::Stopping { turn_id, reason, .. } => {
                self.exit_code = 1;
                self.parent(json!({"type": "result", "turn_id": turn_id, "status": "uncertain",
                                   "reason": reason, "runtime_closed": false}));
            }
            Phase::Idle => self.exit_code = 1,
            Phase::Closing { .. } | Phase::Done => {}
        }
    }

    fn approval_request(&mut self, frame: &Value, now: Instant) {
        let Some(request_id) = frame.get("request_id").filter(|v| v.is_u64()).cloned() else {
            return self.adapter_lost();
        };
        let deny = json!({"type": "approval-decision", "request_id": request_id, "allow": false});
        let Phase::Running(t) = &mut self.phase else { return self.adapter(deny) };
        let approval_id = (self.nonce)();
        let message = json!({"type": "approval", "turn_id": t.id, "approval_id": approval_id,
                             "action": frame.get("action").cloned().unwrap_or(Value::Null),
                             "description": frame.get("description").cloned().unwrap_or(Value::Null),
                             "arguments": frame.get("arguments").cloned().unwrap_or(Value::Null)});
        // Never silently truncate a command the operator is asked to approve.
        if ascii_json_len(&message) > MAX_APPROVAL_FRAME {
            let id = t.id.clone();
            self.parent(json!({"type": "approval-denied", "turn_id": id, "reason": "approval-too-large"}));
            return self.adapter(deny);
        }
        t.approvals.insert(approval_id, Approval { request_id, deadline: now + self.limits.approval });
        self.parent(message);
    }

    fn tool_call(&mut self, frame: &Value, now: Instant) {
        let Some(request_id) = frame.get("request_id").filter(|v| v.is_u64()).cloned() else {
            return self.adapter_lost();
        };
        let reply = |error: &str| tool_result_frame(&request_id, &json!({"ok": false, "error": error}));
        let name = frame.get("name").and_then(Value::as_str).unwrap_or("");
        let Some(spec) = steward_tool(name) else { return self.adapter(reply("unknown_tool")) };
        let Some(arguments) = frame.get("arguments").and_then(Value::as_object) else {
            return self.adapter(reply("bad_arguments"));
        };
        let mut clean = Map::new();
        for (key, value) in arguments {
            let known = spec.required.contains(&key.as_str()) || spec.optional.contains(&key.as_str());
            match value.as_str() {
                Some(v) if known && is_tool_arg(v) => {
                    clean.insert(key.clone(), json!(v));
                }
                _ => return self.adapter(reply("bad_arguments")),
            }
        }
        if spec.required.iter().any(|k| !clean.contains_key(*k)) {
            return self.adapter(reply("bad_arguments"));
        }
        let Phase::Running(t) = &mut self.phase else { return self.adapter(reply("no_active_turn")) };
        if t.tool.is_some() {
            return self.adapter(reply("busy"));
        }
        let tool_id = (self.nonce)();
        let message = json!({"type": "tool", "turn_id": t.id, "tool_id": tool_id, "name": spec.name, "arguments": clean});
        t.tool = Some(PendingTool { tool_id, request_id, deadline: now + self.limits.tool });
        self.parent(message);
    }

    // ── clock ───────────────────────────────────────────────────────────

    pub fn tick(&mut self, now: Instant) {
        match &mut self.phase {
            Phase::Running(t) => {
                if now >= t.deadline {
                    return self.teardown("timeout", false, now);
                }
                let expired: Vec<String> = t.approvals.iter().filter(|(_, a)| now >= a.deadline).map(|(k, _)| k.clone()).collect();
                let id = t.id.clone();
                let mut frames = Vec::new();
                for approval_id in expired {
                    if let Some(a) = t.approvals.remove(&approval_id) {
                        frames.push(Out::Adapter(json!({"type": "approval-decision", "request_id": a.request_id, "allow": false})));
                        frames.push(Out::Parent(json!({"type": "approval-resolved", "turn_id": id, "approval_id": approval_id, "allowed": false})));
                    }
                }
                if t.tool.as_ref().map(|p| now >= p.deadline) == Some(true) {
                    let tool = t.tool.take().expect("checked");
                    frames.push(Out::Adapter(tool_result_frame(&tool.request_id, &json!({"ok": false, "error": "steward_timeout"}))));
                }
                self.out.extend(frames);
            }
            Phase::Stopping { closing, deadline, .. } if now >= *deadline => {
                if *closing {
                    self.finish(false);
                } else {
                    // No answer to interrupt: try the close anyway.
                    *closing = true;
                    *deadline = now + CLOSE_GRACE;
                    self.adapter(json!({"type": "close"}));
                }
            }
            Phase::Closing { deadline } if now >= *deadline => {
                self.exit_code = 1;
                self.phase = Phase::Done;
            }
            _ => {}
        }
    }
}

/// fleet_worker `compose_prompt`: the admitted routing header, never read from the body.
pub fn compose_prompt(body: &str, sender: Option<&str>, room_kind: Option<&str>) -> String {
    if sender.is_none() && room_kind.is_none() {
        return body.to_string();
    }
    let mut header = String::from(if room_kind == Some("family") { "[가족방 메시지" } else { "[개인방 메시지" });
    if let Some(s) = sender {
        header.push_str(" · 보낸 사람: ");
        header.push_str(s);
    }
    format!("{header}]\n{body}")
}

/// The MCP tool result for one steward outcome (`content` text = sorted JSON;
/// `is_error` when not ok), wrapped for the adapter.
fn tool_result_frame(request_id: &Value, outcome: &Value) -> Value {
    let mut outcome = outcome.clone();
    let mut text = py_dumps(&outcome);
    if text.len() > MAX_TEXT_BYTES {
        outcome = json!({"ok": false, "error": "result_too_large"});
        text = py_dumps(&outcome);
    }
    let mut result = json!({"content": [{"type": "text", "text": text}]});
    if outcome.get("ok") != Some(&Value::Bool(true)) {
        result["is_error"] = Value::Bool(true);
    }
    json!({"type": "tool-result", "request_id": request_id, "result": result})
}

/// Size of `value` as `json.dumps(value, ensure_ascii=True)` writes it
/// (`, ` / `: ` separators; non-ASCII as `\uXXXX`, astral as a surrogate pair).
fn ascii_json_len(value: &Value) -> usize {
    py_dumps(value)
        .chars()
        .map(|c| if c.is_ascii() { 1 } else if (c as u32) > 0xFFFF { 12 } else { 6 })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SEC: Duration = Duration::from_secs(1);

    struct Rig {
        m: Machine,
        now: Instant,
        parent: Vec<Value>,
        adapter: Vec<Value>,
    }

    impl Rig {
        fn new() -> Self {
            Rig::with(Limits { turn: 900 * SEC, approval: 120 * SEC, tool: 90 * SEC })
        }
        fn with(limits: Limits) -> Self {
            let mut n = 0;
            let nonce = Box::new(move || {
                n += 1;
                format!("n{n}")
            });
            Rig { m: Machine::new(limits, nonce), now: Instant::now(), parent: Vec::new(), adapter: Vec::new() }
        }
        fn drain(&mut self) {
            for out in self.m.take() {
                match out {
                    Out::Parent(v) => self.parent.push(v),
                    Out::Adapter(v) => self.adapter.push(v),
                }
            }
        }
        fn send(&mut self, v: Value) {
            self.m.parent_line(v.to_string().as_bytes(), self.now);
            self.drain();
        }
        fn feed(&mut self, v: Value) {
            self.m.adapter_frame(v, self.now);
            self.drain();
        }
        fn advance(&mut self, d: Duration) {
            self.now += d;
            self.m.tick(self.now);
            self.drain();
        }
        fn last(&self) -> &Value {
            self.parent.last().expect("a parent frame")
        }
        fn last_adapter(&self) -> &Value {
            self.adapter.last().expect("an adapter frame")
        }
        fn of(&self, kind: &str) -> Vec<&Value> {
            self.parent.iter().filter(|v| v["type"] == kind).collect()
        }
        fn turn(&mut self, id: &str) {
            self.send(json!({"type": "turn", "turn_id": id, "prompt": "synthetic"}));
            self.feed(json!({"type": "session", "session_id": "fixture-session"}));
        }
        /// Adapter acknowledges interrupt and close (`closed_ok`).
        fn settle(&mut self, closed_ok: bool) {
            assert_eq!(self.last_adapter()["type"], "interrupt");
            self.feed(json!({"type": "interrupted", "ok": true}));
            assert_eq!(self.last_adapter()["type"], "close");
            self.feed(json!({"type": "closed", "ok": closed_ok}));
        }
        fn answer(&mut self, text: &str) {
            self.feed(json!({"type": "text", "text": text}));
            self.feed(json!({"type": "completion", "stop_reason": "end_turn"}));
            self.feed(json!({"type": "turn-end", "session_id": "fixture-session"}));
        }
    }

    fn outcome(frame: &Value) -> Value {
        serde_json::from_str(frame["result"]["content"][0]["text"].as_str().unwrap()).unwrap()
    }

    #[test]
    fn completed_turn_and_resume_with_same_worker() {
        let mut r = Rig::new();
        r.turn("one");
        assert_eq!(r.adapter[0], json!({"type": "turn", "prompt": "synthetic", "session_id": null}));
        assert_eq!(r.last(), &json!({"type": "session", "turn_id": "one", "session_id": "fixture-session"}));
        r.answer("synthetic answer");
        assert_eq!(r.last(), &json!({"type": "result", "turn_id": "one", "status": "complete",
                                     "session_id": "fixture-session", "text": "synthetic answer"}));
        r.send(json!({"type": "turn", "turn_id": "two", "prompt": "synthetic", "session_id": "saved"}));
        assert_eq!(r.last_adapter(), &json!({"type": "turn", "prompt": "synthetic", "session_id": "saved"}));
        assert_eq!(r.m.done(), None);
    }

    #[test]
    fn busy_and_wrong_turn_cannot_cancel_current() {
        let mut r = Rig::new();
        r.turn("one");
        r.send(json!({"type": "turn", "turn_id": "two", "prompt": "synthetic"}));
        assert_eq!(r.last(), &json!({"type": "rejected", "turn_id": "two", "reason": "busy"}));
        r.send(json!({"type": "cancel", "turn_id": "two"}));
        assert_eq!(r.last()["accepted"], false);
        assert!(!r.adapter.iter().any(|v| v["type"] == "interrupt"));
        r.send(json!({"type": "cancel", "turn_id": "one"}));
        assert_eq!(r.last()["accepted"], true);
        r.settle(true);
        assert_eq!(r.last(), &json!({"type": "result", "turn_id": "one", "status": "uncertain",
                                     "reason": "cancelled", "runtime_closed": true}));
        assert_eq!(r.m.done(), Some(1), "an uncertain worker retires");
    }

    #[test]
    fn approval_nonce_and_turn_bind_control_and_reject_replay() {
        let mut r = Rig::new();
        r.turn("one");
        r.feed(json!({"type": "approval-request", "request_id": 7, "action": "write",
                      "description": "Synthetic request", "arguments": {"path": "/fixture/synthetic"}}));
        let a = r.last().clone();
        assert_eq!(a["type"], "approval");
        assert_eq!(a["turn_id"], "one");
        assert_eq!(a["arguments"], json!({"path": "/fixture/synthetic"}));
        let adapter_before = r.adapter.len();
        for (turn, nonce) in [("two", a["approval_id"].as_str().unwrap()), ("one", "fake")] {
            r.send(json!({"type": "approve", "turn_id": turn, "approval_id": nonce}));
            assert_eq!(r.last()["accepted"], false);
        }
        assert_eq!(r.adapter.len(), adapter_before, "no decision reached the runtime");
        let command = json!({"type": "approve", "turn_id": "one", "approval_id": a["approval_id"]});
        r.send(command.clone());
        assert_eq!(r.of("control").last().unwrap()["accepted"], true);
        assert_eq!(r.last_adapter(), &json!({"type": "approval-decision", "request_id": 7, "allow": true}));
        assert_eq!(r.last(), &json!({"type": "approval-resolved", "turn_id": "one", "approval_id": a["approval_id"], "allowed": true}));
        r.send(command);
        assert_eq!(r.last()["accepted"], false, "replay refused");
    }

    #[test]
    fn explicit_deny_timeout_and_large_request_fail_closed() {
        // explicit deny
        let mut r = Rig::new();
        r.turn("one");
        r.feed(json!({"type": "approval-request", "request_id": 1, "action": "write", "description": "d", "arguments": {}}));
        let id = r.last()["approval_id"].clone();
        r.send(json!({"type": "deny", "turn_id": "one", "approval_id": id}));
        assert_eq!(r.last_adapter(), &json!({"type": "approval-decision", "request_id": 1, "allow": false}));
        // timeout
        let mut r = Rig::with(Limits { turn: 900 * SEC, approval: SEC, tool: SEC });
        r.turn("one");
        r.feed(json!({"type": "approval-request", "request_id": 2, "action": "write", "description": "d", "arguments": {}}));
        r.advance(SEC);
        assert_eq!(r.last_adapter(), &json!({"type": "approval-decision", "request_id": 2, "allow": false}));
        assert_eq!(r.last()["type"], "approval-resolved");
        assert_eq!(r.last()["allowed"], false);
        // too large: denied, never shown truncated
        let mut r = Rig::new();
        r.turn("one");
        r.feed(json!({"type": "approval-request", "request_id": 3, "action": "write", "description": "x".repeat(60_001), "arguments": {}}));
        assert_eq!(r.last(), &json!({"type": "approval-denied", "turn_id": "one", "reason": "approval-too-large"}));
        assert_eq!(r.last_adapter(), &json!({"type": "approval-decision", "request_id": 3, "allow": false}));
        assert!(r.of("approval").is_empty());
        // non-ASCII counts as its \uXXXX escape (ensure_ascii), so 10,001 Hangul syllables are too large
        let mut r = Rig::new();
        r.turn("one");
        r.feed(json!({"type": "approval-request", "request_id": 4, "action": "write", "description": "가".repeat(10_001), "arguments": {}}));
        assert_eq!(r.last()["type"], "approval-denied");
    }

    #[test]
    fn cancel_during_approval_denies_without_waiting_and_resolves_it() {
        let mut r = Rig::new();
        r.turn("one");
        r.feed(json!({"type": "approval-request", "request_id": 5, "action": "write", "description": "d", "arguments": {}}));
        let id = r.last()["approval_id"].clone();
        r.send(json!({"type": "cancel", "turn_id": "one"}));
        assert!(r.adapter.contains(&json!({"type": "approval-decision", "request_id": 5, "allow": false})));
        assert_eq!(r.of("approval-resolved").last().unwrap()["approval_id"], id);
        r.settle(true);
        assert_eq!(r.last()["reason"], "cancelled");
        let before = r.parent.len();
        r.send(json!({"type": "approve", "turn_id": "one", "approval_id": id}));
        assert_eq!(r.parent.len(), before, "a retired worker answers nothing");
    }

    #[test]
    fn runtime_errors_never_claim_success_or_leak_message() {
        type Script = fn(&mut Rig);
        let scripts: [(&str, Script); 5] = [
            ("error", |r| r.feed(json!({"type": "error"}))),
            ("oversize", |r| r.feed(json!({"type": "text", "text": "x".repeat(65_537)}))),
            ("missing-terminal", |r| {
                r.feed(json!({"type": "text", "text": "synthetic answer"}));
                r.feed(json!({"type": "turn-end", "session_id": "s"}));
            }),
            ("bad-terminal", |r| r.feed(json!({"type": "completion", "stop_reason": "cancelled"}))),
            ("empty-answer", |r| {
                r.feed(json!({"type": "completion", "stop_reason": "end_turn"}));
                r.feed(json!({"type": "turn-end", "session_id": "s"}));
            }),
        ];
        for (name, script) in scripts {
            let mut r = Rig::new();
            r.turn("one");
            script(&mut r);
            r.settle(true);
            let result = r.of("result");
            assert_eq!(result.len(), 1, "{name}");
            assert_eq!(result[0]["status"], "uncertain", "{name}");
            assert_eq!(result[0]["reason"], "runtime-error", "{name}");
            assert!(result[0].get("text").is_none(), "{name}");
        }
    }

    #[test]
    fn timeout_interrupts_and_closes_on_unconfirmed_stop() {
        let mut r = Rig::with(Limits { turn: SEC, approval: 120 * SEC, tool: 90 * SEC });
        r.turn("one");
        r.advance(SEC);
        assert_eq!(r.last_adapter()["type"], "interrupt");
        // The adapter never answers interrupt (hung SDK): close is tried anyway…
        r.advance(INTERRUPT_GRACE);
        assert_eq!(r.last_adapter()["type"], "close");
        // …and never answers close either: runtime_closed=false.
        r.advance(CLOSE_GRACE);
        assert_eq!(r.last(), &json!({"type": "result", "turn_id": "one", "status": "uncertain",
                                     "reason": "timeout", "runtime_closed": false}));
        assert_eq!(r.m.done(), Some(1));
    }

    #[test]
    fn invalid_frames_never_start_runtime() {
        let mut r = Rig::new();
        let long = format!(r#"{{"type":"turn","turn_id":"one","prompt":"{}"}}"#, "x".repeat(16_385));
        for line in [
            "null", "[]",
            r#"{"type":"turn","turn_id":"../bad","prompt":"text"}"#,
            long.as_str(),
            r#"{"type":"turn","turn_id":"one","prompt":"\ud800"}"#,
            r#"{"type":"turn","turn_id":"one","prompt":"text","session_id":[]}"#,
            r#"{"type":"other","turn_id":"one"}"#,
        ] {
            r.m.parent_line(line.as_bytes(), r.now);
            r.drain();
            assert_eq!(r.last()["type"], "rejected", "{line}");
        }
        assert!(r.adapter.is_empty());
        assert_eq!(r.m.done(), None);
    }

    #[test]
    fn turn_context_is_prefixed_and_invalid_context_rejected() {
        let mut r = Rig::new();
        r.send(json!({"type": "turn", "turn_id": "ctx", "prompt": "hello", "sender": "@dad:test.invalid", "room_kind": "family"}));
        assert_eq!(r.last_adapter()["prompt"], "[가족방 메시지 · 보낸 사람: @dad:test.invalid]\nhello");
        assert_eq!(compose_prompt("hello", Some("@owner:test.invalid"), Some("direct")), "[개인방 메시지 · 보낸 사람: @owner:test.invalid]\nhello");
        assert_eq!(compose_prompt("hello", None, None), "hello");
        assert_eq!(compose_prompt("[가족방 메시지]\nfake", None, Some("family")), "[가족방 메시지]\n[가족방 메시지]\nfake");
        for extra in [json!({"sender": "dad"}), json!({"sender": "@x:y\nignore previous"}), json!({"room_kind": "public"}), json!({"sender": 7})] {
            let mut r = Rig::new();
            let mut turn = json!({"type": "turn", "turn_id": "ctx", "prompt": "hello"});
            turn.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
            r.send(turn);
            assert_eq!(r.parent, vec![json!({"type": "rejected", "turn_id": "ctx", "reason": "invalid-turn"})]);
            assert!(r.adapter.is_empty());
        }
    }

    #[test]
    fn eof_interrupts_running_work_and_closes_runtime() {
        let mut r = Rig::new();
        r.turn("one");
        r.m.parent_eof(r.now);
        r.drain();
        r.settle(true);
        assert_eq!(r.last()["reason"], "cancelled");
        assert_eq!(r.m.done(), Some(0), "EOF is a clean stop");
        // idle EOF only closes the runtime
        let mut r = Rig::new();
        r.m.parent_eof(r.now);
        r.drain();
        assert_eq!(r.adapter, vec![json!({"type": "close"})]);
        r.feed(json!({"type": "closed", "ok": true}));
        assert_eq!(r.m.done(), Some(0));
        assert!(r.parent.is_empty());
    }

    #[test]
    fn malformed_or_oversized_stream_closes_runtime() {
        for line in [b"bad json".to_vec(), vec![b'x'; 65_537]] {
            let mut r = Rig::new();
            r.m.parent_line(&line, r.now);
            r.drain();
            assert_eq!(r.adapter, vec![json!({"type": "close"})]);
            r.feed(json!({"type": "closed", "ok": true}));
            assert_eq!(r.m.done(), Some(1));
        }
    }

    #[test]
    fn repeat_cancel_and_eof_cannot_cancel_interrupt_cleanup() {
        let mut r = Rig::new();
        r.turn("one");
        r.send(json!({"type": "cancel", "turn_id": "one"}));
        let frames = r.parent.len();
        r.send(json!({"type": "cancel", "turn_id": "one"}));
        r.m.parent_eof(r.now);
        r.drain();
        assert_eq!(r.parent.len(), frames, "nothing answered while cleaning up");
        assert_eq!(r.adapter.iter().filter(|v| v["type"] == "interrupt").count(), 1);
        r.settle(true);
        assert_eq!(r.of("result").len(), 1);
        assert_eq!(r.m.done(), Some(1));
    }

    #[test]
    fn output_failure_terminates_and_closes_runtime() {
        let mut r = Rig::new();
        r.turn("one");
        r.m.output_failed(r.now);
        r.drain();
        r.settle(true);
        assert_eq!(r.m.done(), Some(1));
    }

    #[test]
    fn start_response_race_retires_runtime_even_when_interrupt_noops() {
        for mode in ["cancel", "timeout", "eof"] {
            let mut r = Rig::with(Limits { turn: SEC, approval: 120 * SEC, tool: 90 * SEC });
            r.turn("one");
            match mode {
                "cancel" => r.send(json!({"type": "cancel", "turn_id": "one"})),
                "timeout" => r.advance(SEC),
                _ => {
                    r.m.parent_eof(r.now);
                    r.drain()
                }
            }
            r.settle(true);
            let result = r.of("result")[0].clone();
            assert_eq!((result["status"].as_str(), result["runtime_closed"].as_bool()), (Some("uncertain"), Some(true)), "{mode}");
            assert!(r.m.done().is_some(), "{mode}");
            assert_eq!(r.adapter.iter().filter(|v| v["type"] == "turn").count(), 1);
        }
    }

    #[test]
    fn a_failed_or_silent_close_at_shutdown_exits_1() {
        // idle EOF, adapter says closed ok=false
        let mut r = Rig::new();
        r.m.parent_eof(r.now);
        r.drain();
        r.feed(json!({"type": "closed", "ok": false}));
        assert_eq!(r.m.done(), Some(1));
        // idle EOF, adapter never answers
        let mut r = Rig::new();
        r.m.parent_eof(r.now);
        r.drain();
        r.advance(CLOSE_GRACE);
        assert_eq!(r.m.done(), Some(1));
        // EOF during a turn whose runtime does not close
        let mut r = Rig::new();
        r.turn("one");
        r.m.parent_eof(r.now);
        r.drain();
        r.settle(false);
        assert_eq!(r.last()["runtime_closed"], false);
        assert_eq!(r.m.done(), Some(1));
    }

    #[test]
    fn runtime_close_failure_is_explicit() {
        let mut r = Rig::new();
        r.turn("one");
        r.send(json!({"type": "cancel", "turn_id": "one"}));
        r.settle(false);
        assert_eq!(r.last()["runtime_closed"], false);
    }

    #[test]
    fn adapter_loss_reports_uncertain_once() {
        let mut r = Rig::new();
        r.turn("one");
        r.m.adapter_lost();
        r.drain();
        assert_eq!(r.last(), &json!({"type": "result", "turn_id": "one", "status": "uncertain",
                                     "reason": "runtime-error", "runtime_closed": false}));
        assert_eq!(r.m.done(), Some(1));
        let mut r = Rig::new();
        r.m.adapter_lost();
        r.drain();
        assert!(r.parent.is_empty());
        assert_eq!(r.m.done(), Some(1));
    }

    // ── steward tools (#372 P4 / #378) ──────────────────────────────────

    fn tool(r: &mut Rig, request_id: u64, name: &str, arguments: Value) {
        r.feed(json!({"type": "tool-call", "request_id": request_id, "name": name, "arguments": arguments}));
    }

    #[test]
    fn tool_frame_round_trip_and_result_reaches_the_model() {
        let mut r = Rig::new();
        r.turn("one");
        tool(&mut r, 11, "room_invite", json!({"room": "family", "device": "jungin-iphone-1b89e3"}));
        let frame = r.last().clone();
        assert_eq!(frame["type"], "tool");
        assert_eq!(frame["turn_id"], "one");
        assert_eq!(frame["name"], "room_invite");
        assert_eq!(frame["arguments"], json!({"room": "family", "device": "jungin-iphone-1b89e3"}));
        r.send(json!({"type": "tool-result", "turn_id": "one", "tool_id": frame["tool_id"], "ok": true,
                      "result": {"op": "invite", "room": "family", "pending": true, "seq": 3}}));
        assert_eq!(r.last()["accepted"], true);
        let reply = r.last_adapter().clone();
        assert_eq!(reply["request_id"], 11);
        assert!(reply["result"].get("is_error").is_none());
        assert_eq!(outcome(&reply), json!({"ok": true, "result": {"op": "invite", "room": "family", "pending": true, "seq": 3}}));
        assert_eq!(reply["result"]["content"][0]["text"],
                   r#"{"ok": true, "result": {"op": "invite", "pending": true, "room": "family", "seq": 3}}"#);
    }

    #[test]
    fn room_close_is_forwarded_with_the_room_only() {
        let mut r = Rig::new();
        r.turn("one");
        tool(&mut r, 1, "room_close", json!({"room": "lobby-test"}));
        assert_eq!((r.last()["name"].clone(), r.last()["arguments"].clone()), (json!("room_close"), json!({"room": "lobby-test"})));
    }

    #[test]
    fn parent_refusal_is_an_error_result_not_an_exception() {
        let mut r = Rig::new();
        r.turn("one");
        tool(&mut r, 1, "room_remove", json!({"room": "family", "device": "owner-pc"}));
        let id = r.last()["tool_id"].clone();
        r.send(json!({"type": "tool-result", "turn_id": "one", "tool_id": id, "ok": false, "error": "owner_only"}));
        assert_eq!(r.last_adapter()["result"]["is_error"], true);
        assert_eq!(outcome(r.last_adapter()), json!({"ok": false, "error": "owner_only"}));
        tool(&mut r, 2, "room_status", json!({}));
        let id = r.last()["tool_id"].clone();
        r.send(json!({"type": "tool-result", "turn_id": "one", "tool_id": id, "ok": "yes", "error": ""}));
        assert_eq!(outcome(r.last_adapter()), json!({"ok": false, "error": "steward_error"}));
    }

    #[test]
    fn one_tool_at_a_time_and_unmatched_results_are_ignored() {
        let mut r = Rig::new();
        r.turn("one");
        tool(&mut r, 1, "room_members", json!({"room": "family"}));
        let id = r.last()["tool_id"].clone();
        tool(&mut r, 2, "room_status", json!({}));
        assert_eq!(r.last_adapter()["request_id"], 2);
        assert_eq!(outcome(r.last_adapter()), json!({"ok": false, "error": "busy"}));
        for (turn, tool_id) in [(json!("two"), id.clone()), (json!("one"), json!("not-a-nonce"))] {
            let adapter = r.adapter.len();
            r.send(json!({"type": "tool-result", "turn_id": turn, "tool_id": tool_id, "ok": true, "result": {}}));
            assert_eq!(r.last()["accepted"], false);
            assert_eq!(r.adapter.len(), adapter);
        }
        r.send(json!({"type": "tool-result", "turn_id": "one", "tool_id": id, "ok": true, "result": {"members": []}}));
        assert_eq!(outcome(r.last_adapter())["ok"], true);
        r.send(json!({"type": "tool-result", "turn_id": "one", "tool_id": id, "ok": true, "result": {}}));
        assert_eq!(r.last()["accepted"], false);
    }

    #[test]
    fn arguments_are_validated_before_any_frame_leaves() {
        let mut r = Rig::new();
        r.turn("one");
        let bad = [
            ("room_invite", json!({"room": "family"})),
            ("room_invite", json!({"room": "family", "device": "x y"})),
            ("room_invite", json!({"room": "family", "device": "a", "extra": "b"})),
            ("room_status", json!({"room": "family"})),
            ("room_mode", json!({"room": "family", "mode": "a".repeat(65)})),
            ("room_members", json!("family")),
            ("room_members", json!({"room": 7})),
            ("room_close", json!({})),
            ("room_close", json!({"room": "family", "device": "owner-pc"})),
        ];
        for (i, (name, arguments)) in bad.into_iter().enumerate() {
            tool(&mut r, i as u64, name, arguments.clone());
            assert_eq!(outcome(r.last_adapter()), json!({"ok": false, "error": "bad_arguments"}), "{name} {arguments}");
        }
        tool(&mut r, 99, "room_nuke", json!({"room": "family"}));
        assert_eq!(outcome(r.last_adapter()), json!({"ok": false, "error": "unknown_tool"}));
        assert!(r.of("tool").is_empty());
    }

    #[test]
    fn no_active_turn_timeout_and_cancel_fail_closed() {
        let mut r = Rig::with(Limits { turn: 900 * SEC, approval: 120 * SEC, tool: SEC });
        tool(&mut r, 1, "room_status", json!({}));
        assert_eq!(outcome(r.last_adapter()), json!({"ok": false, "error": "no_active_turn"}));
        r.turn("one");
        tool(&mut r, 2, "room_status", json!({}));
        r.advance(SEC);
        assert_eq!(outcome(r.last_adapter()), json!({"ok": false, "error": "steward_timeout"}));
        tool(&mut r, 3, "room_create", json!({"room": "family", "mode": "silent"}));
        assert_eq!(r.last()["type"], "tool", "the timed-out slot is free again");
        r.send(json!({"type": "cancel", "turn_id": "one"}));
        let cancelled = r.adapter.iter().find(|v| v["type"] == "tool-result" && v["request_id"] == 3).unwrap().clone();
        assert_eq!(outcome(&cancelled), json!({"ok": false, "error": "cancelled"}));
        r.settle(true);
        assert_eq!(r.last()["status"], "uncertain");
    }

    #[test]
    fn oversized_tool_result_is_replaced_not_cut() {
        let mut r = Rig::new();
        r.turn("one");
        tool(&mut r, 1, "room_status", json!({}));
        let id = r.last()["tool_id"].clone();
        r.send(json!({"type": "tool-result", "turn_id": "one", "tool_id": id, "ok": true, "result": {"blob": "x".repeat(MAX_TEXT_BYTES)}}));
        assert_eq!(outcome(r.last_adapter()), json!({"ok": false, "error": "result_too_large"}));
        assert_eq!(r.last_adapter()["result"]["is_error"], true);
    }

    #[test]
    fn adapter_requests_without_a_turn_are_denied() {
        let mut r = Rig::new();
        r.feed(json!({"type": "approval-request", "request_id": 1, "action": "write", "description": "d", "arguments": {}}));
        assert_eq!(r.last_adapter(), &json!({"type": "approval-decision", "request_id": 1, "allow": false}));
        assert!(r.parent.is_empty());
        r.feed(json!({"type": "approval-request", "action": "no id"}));
        assert_eq!(r.m.done(), Some(1), "a request without request_id is a protocol break");
    }
}
