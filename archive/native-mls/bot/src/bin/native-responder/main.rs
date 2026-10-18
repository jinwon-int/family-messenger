//! `native-responder` (#396): the agent responder runtime in Rust.
//!
//! Speaks the node-local JSON-lines port of `docs/FLEET-WORKER.md` on
//! stdin/stdout (a pipe from `fleet_matrix.py`, or the systemd `Accept=yes`
//! socket the native-mls bot connects to) — byte-for-byte the frames
//! `scripts/fleet_worker.py` speaks, so neither parent changes. Turn
//! serialization, timeouts, approval nonces, steward tool validation and the
//! uncertain/retire rule live here (`machine.rs`).
//!
//! The only Python left is the ccc-node harness call: this process spawns
//! `scripts/ccc_adapter.py` (argv from `--adapter-argv-json`, no shell) on
//! pipes, sends it one `configure` frame built from the same flags
//! fleet_worker took (`harness.rs`), and relays `turn` / approvals / tool
//! calls / `interrupt` / `close` over a small adapter protocol
//! (`docs/FLEET-WORKER.md` §어댑터 프로토콜). AI credentials stay in the
//! adapter's interpreter; nothing crosses to the parent.

mod harness;
mod machine;
mod wire;

use machine::{Limits, Machine, Out};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, ChildStdin, Command, ExitCode, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

/// How long the adapter may take to import ccc-node and answer `ready`.
const READY_TIMEOUT: Duration = Duration::from_secs(120);
/// A parent that has not taken a frame within this is gone (fleet_worker: 5 s).
const OUTPUT_STALL: Duration = Duration::from_secs(5);
/// Adapter frames carry raw approval arguments; above this the adapter is broken.
const MAX_ADAPTER_FRAME: usize = 16 * 1024 * 1024;

enum Event {
    Parent(Vec<u8>),
    ParentEof,
    ParentBad,
    Adapter(Value),
    AdapterLost,
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.iter().any(|a| a == "--help" || a == "-h") {
        println!("{}", harness::USAGE);
        return ExitCode::SUCCESS;
    }
    let args = match harness::parse_args(&argv, std::env::var("NATIVE_RESPONDER_ADAPTER_ARGV_JSON").ok()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("native-responder: {e}\n{}", harness::USAGE);
            return ExitCode::from(2);
        }
    };
    let (turn, approval, tool) = match args.timeouts() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("native-responder: {e}");
            return ExitCode::from(2);
        }
    };
    let environment: BTreeMap<String, String> = std::env::vars().collect();
    let configure = match harness::configure_frame(&args, &environment) {
        Ok(frame) => frame,
        Err(e) => {
            eprintln!("native-responder: {e}");
            return ExitCode::from(1);
        }
    };
    let mut child = match Command::new(&args.adapter_argv[0])
        .args(&args.adapter_argv[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => {
            eprintln!("native-responder: adapter did not start");
            return ExitCode::from(1);
        }
    };
    let (tx, rx) = mpsc::channel::<Event>();
    let adapter_out = child.stdout.take().expect("piped");
    spawn_adapter_reader(adapter_out, tx.clone());
    let mut adapter_in = child.stdin.take().expect("piped");

    if write_frame(&mut adapter_in, &configure).is_err() || !await_ready(&rx) {
        eprintln!("native-responder: adapter not ready; inspect the adapter's stderr");
        stop_child(&mut child, None);
        return ExitCode::from(1);
    }

    spawn_parent_reader(tx);
    let output = spawn_parent_writer();
    let limits = Limits { turn, approval, tool };
    let mut machine = Machine::new(limits, Box::new(wire::nonce));
    let mut output_dead = false;
    let mut adapter_in = Some(adapter_in);
    let code = loop {
        // Flush everything the machine produced (failures may add more).
        loop {
            let frames = machine.take();
            if frames.is_empty() {
                break;
            }
            for frame in frames {
                match frame {
                    Out::Parent(value) => {
                        if !output_dead && !output.send(&value) {
                            output_dead = true;
                            machine.output_failed(Instant::now());
                        }
                    }
                    Out::Adapter(value) => {
                        let failed = match adapter_in.as_mut() {
                            Some(pipe) => write_frame(pipe, &value).is_err(),
                            None => true,
                        };
                        if failed {
                            adapter_in = None;
                            machine.adapter_lost();
                        }
                    }
                }
            }
        }
        if let Some(code) = machine.done() {
            break code;
        }
        let wait = machine
            .next_deadline()
            .map(|d| d.saturating_duration_since(Instant::now()))
            .unwrap_or(Duration::from_secs(3600));
        match rx.recv_timeout(wait) {
            Ok(Event::Parent(line)) => machine.parent_line(&line, Instant::now()),
            Ok(Event::ParentEof) => machine.parent_eof(Instant::now()),
            Ok(Event::ParentBad) => machine.fatal(Instant::now()),
            Ok(Event::Adapter(frame)) => machine.adapter_frame(frame, Instant::now()),
            Ok(Event::AdapterLost) => machine.adapter_lost(),
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => machine.adapter_lost(),
        }
        machine.tick(Instant::now());
    };
    stop_child(&mut child, adapter_in);
    if code != 0 {
        eprintln!("fleet worker stopped; inspect body-free parent status");
    }
    ExitCode::from(code)
}

fn write_frame(pipe: &mut ChildStdin, value: &Value) -> std::io::Result<()> {
    let mut line = serde_json::to_vec(value)?;
    line.push(b'\n');
    pipe.write_all(&line)?;
    pipe.flush()
}

fn await_ready(rx: &Receiver<Event>) -> bool {
    let deadline = Instant::now() + READY_TIMEOUT;
    loop {
        match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(Event::Adapter(frame)) => match frame.get("type").and_then(Value::as_str) {
                Some("ready") => return frame.get("protocol") == Some(&Value::from(1)),
                Some("fatal") => return false,
                _ => continue,
            },
            _ => return false,
        }
    }
}

/// EOF on its stdin lets the adapter exit by itself; a stuck one is killed.
fn stop_child(child: &mut Child, stdin: Option<ChildStdin>) {
    drop(stdin);
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        if let Ok(Some(_)) = child.try_wait() {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = child.kill();
    let _ = child.wait();
}

/// One line at a time, at most `limit` bytes (newline included); `Err` on overflow.
fn read_capped_line(reader: &mut impl BufRead, limit: usize) -> std::io::Result<Option<Result<Vec<u8>, ()>>> {
    let mut line = Vec::new();
    let n = reader.by_ref().take(limit as u64 + 1).read_until(b'\n', &mut line)?;
    if n == 0 {
        return Ok(None);
    }
    if line.len() > limit {
        return Ok(Some(Err(())));
    }
    Ok(Some(Ok(line)))
}

fn spawn_adapter_reader(out: impl Read + Send + 'static, tx: Sender<Event>) {
    std::thread::spawn(move || {
        let mut reader = BufReader::new(out);
        loop {
            let event = match read_capped_line(&mut reader, MAX_ADAPTER_FRAME) {
                Ok(Some(Ok(line))) => match serde_json::from_slice::<Value>(&line) {
                    Ok(v) if v.is_object() => Event::Adapter(v),
                    _ => Event::AdapterLost,
                },
                _ => Event::AdapterLost,
            };
            let lost = matches!(event, Event::AdapterLost);
            if tx.send(event).is_err() || lost {
                return;
            }
        }
    });
}

fn spawn_parent_reader(tx: Sender<Event>) {
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        let mut reader = stdin.lock();
        loop {
            let event = match read_capped_line(&mut reader, wire::MAX_INPUT_FRAME) {
                Ok(Some(Ok(line))) => Event::Parent(line),
                Ok(Some(Err(()))) | Err(_) => Event::ParentBad,
                Ok(None) => Event::ParentEof,
            };
            let last = !matches!(event, Event::Parent(_));
            if tx.send(event).is_err() || last {
                return;
            }
        }
    });
}

/// Writes to the parent on a thread so a stalled reader cannot block the
/// state machine: each frame must be taken within `OUTPUT_STALL`.
struct ParentWriter {
    frames: Sender<Vec<u8>>,
    acks: Receiver<bool>,
}

impl ParentWriter {
    fn send(&self, value: &Value) -> bool {
        let Ok(mut line) = serde_json::to_vec(value) else { return false };
        line.push(b'\n');
        if line.len() > wire::MAX_OUTPUT_FRAME || self.frames.send(line).is_err() {
            return false;
        }
        matches!(self.acks.recv_timeout(OUTPUT_STALL), Ok(true))
    }
}

fn spawn_parent_writer() -> ParentWriter {
    let (frames, rx) = mpsc::channel::<Vec<u8>>();
    let (ack_tx, acks) = mpsc::channel::<bool>();
    std::thread::spawn(move || {
        let stdout = std::io::stdout();
        for line in rx {
            let mut out = stdout.lock();
            let ok = out.write_all(&line).and_then(|_| out.flush()).is_ok();
            if ack_tx.send(ok).is_err() || !ok {
                return;
            }
        }
    });
    ParentWriter { frames, acks }
}
