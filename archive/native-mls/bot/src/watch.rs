//! #755 (bot step): wait for relay changes with `GET /v2/watch` (#424,
//! `server/wait.go`) instead of reading every room on every round.
//!
//! The session loop (`session.rs` `run_rounds`) is one thread. Each round it
//! reads the rooms, serves one steward command, pumps the responder (worker
//! frames, watchdog, approvals, attachments, reconnect) and the typing
//! keepalive, then waits `POLL`. A long-poll on that thread would hold all of
//! that back for as long as the relay stays quiet, so the blocking request
//! runs on its own thread here. The loop still waits at most `POLL` between
//! rounds, exactly like the sleep this replaces; a watch answer only ends that
//! wait early.
//!
//! What changes is which rooms a round reads ([`Plan::sweep`]):
//!
//! - While a watch covers the wait before a round, the round reads only the
//!   rooms that watch named (changed or refused), rooms it did not carry, and
//!   rooms with work of their own (the caller's `needs_poll`).
//! - Whenever no watch covered that wait — switched off, an old relay, an
//!   error, the gap between two watches, an overdue answer — the round reads
//!   every room, which is the loop as it was before.
//! - Every [`SAFETY_SWEEP`] a round reads every room anyway, and so does the
//!   round after a steward command or a 409 on an outbound attachment (the
//!   caller's `force_full`), which both counted on the next read.
//!
//! So a new row is found either by the watch (at once) or by a full round
//! within `POLL`, never later than with plain polling.
//!
//! Rules and constants follow the hosts that already use `/v2/watch`
//! (web `web/hande/watch-loop.js` · `relay.js`, Android `core/DeviceHub.kt` ·
//! `core/WatchPlan.kt`, iOS `Sync/WatchWaiter.swift`); the retry delay after an
//! error is the bot's own relay backoff (`room::relay_backoff`, #392).

use crate::api::{self, BotError};
use native_mls_host::room::relay_backoff;
use std::collections::BTreeSet;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::{Duration, Instant};

/// How long one watch may wait on the relay. Android `DeviceHub.WATCH_WAIT_MS`
/// (the relay caps at `api::WATCH_WAIT_MAX_MS`, which the web uses): the bot
/// re-reads its access token only when it sends a request, so the shorter
/// wait bounds how long an expired token or a silently dead connection goes
/// unnoticed.
pub const WAIT_MS: u32 = 12_000;
/// Read timeout of the watch request beyond [`WAIT_MS`] (web `relay.js`
/// `WATCH_TIMEOUT_MARGIN_MS`). A watch still unanswered after wait + margin
/// counts as not covering anything ([`Plan::sweep`]).
pub const TIMEOUT_MARGIN: Duration = Duration::from_secs(10);
/// Least time between two watch requests (web `MIN_GAP_MS`, Android
/// `MIN_TICK_GAP_MS`, iOS `minGap`), so a relay that keeps answering at once
/// is asked once a second at most. Rounds in between read every room.
pub const MIN_GAP: Duration = Duration::from_secs(1);
/// Every room is read at least this often whatever the watch says (web
/// `SAFETY_POLL_MS`, Android `WatchPlan.SAFETY_SWEEP_MS`).
pub const SAFETY_SWEEP: Duration = Duration::from_secs(60);
/// A relay without `/v2/watch` is asked again after this long (web
/// `REPROBE_MS`, iOS `reprobeInterval`, Android 75 ticks of 4 s).
pub const REPROBE: Duration = Duration::from_secs(300);
/// Same as host-core's own connect timeout (`http.rs`, private there).
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// What one watch request came to.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The relay answered: the rooms to read now — those with rows after their
    /// offset or a change while waiting, and those it refused (`no_such_room`,
    /// `room_closed`; the room's own read reports them as before). Empty = the
    /// wait ran out.
    Watched(Vec<String>),
    /// A relay that predates `/v2/watch` (plain 404).
    Unsupported,
    /// No usable answer (connection, timeout, 401, 5xx …).
    Failed(String),
}

/// Whether rounds currently lean on the watch, for the log and `status`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Watch,
    /// Plain polling, and why: `starting` (no answer yet), `disabled`,
    /// `unsupported`, `error`, `watcher_gone`.
    Poll(&'static str),
}

impl Mode {
    pub fn name(self) -> &'static str {
        match self { Mode::Watch => "watch", Mode::Poll(_) => "poll" }
    }
    pub fn reason(self) -> Option<&'static str> {
        match self { Mode::Watch => None, Mode::Poll(why) => Some(why) }
    }
    /// For `status`: `starting` until the first watch answers (up to one
    /// [`WAIT_MS`] in a quiet session), then `watch` or `poll`.
    pub fn label(self) -> &'static str {
        match self { Mode::Poll("starting") => "starting", other => other.name() }
    }
}

/// A mode change, reported once (`relay_watch` log line).
#[derive(Debug, PartialEq, Eq)]
pub struct Shift {
    pub mode: Mode,
    /// Rooms the answered request carried.
    pub rooms: usize,
    pub error: Option<String>,
    /// When the next watch is tried (error backoff, reprobe).
    pub retry: Option<Duration>,
}

/// Which rooms one round reads.
#[derive(Debug, PartialEq, Eq)]
pub enum Sweep {
    /// Every room — the loop without a watch.
    Full,
    /// The rooms the watch named and the rooms it did not carry.
    Hinted { hinted: BTreeSet<String>, covered: BTreeSet<String> },
}

impl Sweep {
    pub fn reads(&self, room: &str) -> bool {
        match self {
            Sweep::Full => true,
            Sweep::Hinted { hinted, covered } => hinted.contains(room) || !covered.contains(room),
        }
    }
}

/// The watch rules as plain state: no thread, no socket, the clock passed in.
#[derive(Debug)]
pub struct Plan {
    enabled: bool,
    /// When the request in flight was sent.
    flight: Option<Instant>,
    /// Rooms of the request in flight, or of the one answered last.
    covered: BTreeSet<String>,
    /// Rooms named by answers no round has read yet.
    hinted: BTreeSet<String>,
    /// A watch answered since the last sweep: the wait before this round was
    /// covered up to that answer.
    fresh: bool,
    /// The next sweep reads every room (unusable answer, a failed read).
    full_next: bool,
    last_full: Option<Instant>,
    last_start: Option<Instant>,
    /// No watch before this (error backoff, reprobe).
    not_before: Option<Instant>,
    failures: u32,
    mode: Mode,
}

impl Plan {
    pub fn new(enabled: bool) -> Plan {
        Plan {
            enabled, flight: None, covered: BTreeSet::new(), hinted: BTreeSet::new(), fresh: false, full_next: false,
            last_full: None, last_start: None, not_before: None, failures: 0,
            mode: Mode::Poll(if enabled { "starting" } else { "disabled" }),
        }
    }

    pub fn mode(&self) -> Mode { self.mode }

    /// Start of a round. Reads every room unless a watch covered the wait
    /// that just ended: one still in flight and not overdue, or one that
    /// answered during it. The first round and every [`SAFETY_SWEEP`] read
    /// every room regardless.
    pub fn sweep(&mut self, now: Instant) -> Sweep {
        let waiting = self.flight.is_some_and(|sent| now.saturating_duration_since(sent) <= Duration::from_millis(WAIT_MS.into()) + TIMEOUT_MARGIN);
        let covered = std::mem::take(&mut self.fresh) || waiting;
        let safety = self.last_full.is_none_or(|at| now.saturating_duration_since(at) >= SAFETY_SWEEP);
        if !self.enabled || std::mem::take(&mut self.full_next) || !covered || safety {
            self.hinted.clear();
            self.last_full = Some(now);
            return Sweep::Full;
        }
        Sweep::Hinted { hinted: std::mem::take(&mut self.hinted), covered: self.covered.clone() }
    }

    /// The round could not finish its reads (relay unreachable, auth wait):
    /// the next one reads every room again.
    pub fn force_full(&mut self) { self.full_next = true; }

    /// End of a round: may a watch be sent now? Not while one is in flight,
    /// before the backoff/reprobe time, or within [`MIN_GAP`] of the last start.
    pub fn due(&self, now: Instant) -> bool {
        self.enabled
            && self.flight.is_none()
            && self.not_before.is_none_or(|at| now >= at)
            && self.last_start.is_none_or(|at| now.saturating_duration_since(at) >= MIN_GAP)
    }

    /// A watch for `rooms` was sent.
    pub fn sent(&mut self, now: Instant, rooms: impl IntoIterator<Item = String>) {
        self.flight = Some(now);
        self.last_start = Some(now);
        self.covered = rooms.into_iter().collect();
    }

    /// The watch in flight answered. `Some` when the mode changed.
    pub fn settle(&mut self, now: Instant, outcome: Outcome) -> Option<Shift> {
        self.flight.take()?;
        let rooms = self.covered.len();
        let (mode, error, retry) = match outcome {
            Outcome::Watched(named) => {
                self.failures = 0;
                self.hinted.extend(named);
                self.fresh = true;
                (Mode::Watch, None, None)
            }
            Outcome::Unsupported => {
                self.failures = 0;
                self.full_next = true;
                (Mode::Poll("unsupported"), None, Some(REPROBE))
            }
            Outcome::Failed(error) => {
                self.failures = self.failures.saturating_add(1);
                self.full_next = true;
                (Mode::Poll("error"), Some(error), Some(relay_backoff(self.failures)))
            }
        };
        self.not_before = retry.and_then(|wait| now.checked_add(wait));
        if mode == self.mode {
            return None;
        }
        self.mode = mode;
        Some(Shift { mode, rooms, error, retry })
    }
}

struct Link {
    requests: mpsc::Sender<Vec<(String, i64)>>,
    outcomes: mpsc::Receiver<Outcome>,
}

/// The loop's handle: the [`Plan`] plus the thread that runs the requests.
pub struct RelayWatch {
    plan: Plan,
    link: Option<Link>,
}

impl RelayWatch {
    /// Plain polling (`--no-relay-watch`, unit tests against scripted relays).
    pub fn off() -> RelayWatch {
        RelayWatch { plan: Plan::new(false), link: None }
    }

    /// Watch `base` as `device`. The request thread owns its own client, so
    /// the access token file is re-read per request like everywhere else.
    pub fn relay(base: &str, access: api::Access, device: &str) -> RelayWatch {
        let (base, device) = (base.to_string(), device.to_string());
        RelayWatch::spawn(move |targets| {
            let client = api::Client::with_transport(&base, access.clone(), Box::new(WatchTransport));
            let rooms: Vec<(&str, i64)> = targets.iter().map(|(room, after)| (room.as_str(), *after)).collect();
            outcome(client.watch(&device, &rooms, WAIT_MS))
        })
    }

    /// `call` runs one blocking watch for `(room, offset)` pairs on the request thread.
    pub fn spawn(mut call: impl FnMut(&[(String, i64)]) -> Outcome + Send + 'static) -> RelayWatch {
        let (requests, todo) = mpsc::channel::<Vec<(String, i64)>>();
        let (done, outcomes) = mpsc::channel();
        let thread = std::thread::Builder::new().name("relay-watch".into()).spawn(move || {
            // Ends when the loop drops its handle (either channel closes).
            while let Ok(targets) = todo.recv() {
                if done.send(call(&targets)).is_err() {
                    break;
                }
            }
        });
        match thread {
            Ok(_) => RelayWatch { plan: Plan::new(true), link: Some(Link { requests, outcomes }) },
            Err(_) => RelayWatch { plan: Plan { mode: Mode::Poll("watcher_gone"), ..Plan::new(false) }, link: None },
        }
    }

    pub fn mode(&self) -> Mode { self.plan.mode() }

    pub fn sweep(&mut self, now: Instant) -> Sweep { self.plan.sweep(now) }

    pub fn force_full(&mut self) { self.plan.force_full(); }

    /// End of a round, after its reads: send a watch when one is due.
    /// `targets` = `(room, offset)` of the rooms worth waiting on; the first
    /// `api::WATCH_MAX_ROOMS` are sent, the rest keep being read every round.
    pub fn arm(&mut self, now: Instant, targets: impl FnOnce() -> Vec<(String, i64)>) -> Option<Shift> {
        let link = self.link.as_ref()?;
        if !self.plan.due(now) {
            return None;
        }
        let mut targets = targets();
        targets.truncate(api::WATCH_MAX_ROOMS);
        if targets.is_empty() {
            return None;
        }
        let rooms: Vec<String> = targets.iter().map(|(room, _)| room.clone()).collect();
        if link.requests.send(targets).is_err() {
            return Some(self.lost());
        }
        self.plan.sent(now, rooms);
        None
    }

    /// The wait between two rounds: `max` at most — the fixed sleep it
    /// replaces — and shorter when the watch in flight answers.
    pub fn wait(&mut self, max: Duration) -> Option<Shift> {
        let Some(link) = self.link.as_ref().filter(|_| self.plan.flight.is_some()) else {
            std::thread::sleep(max);
            return None;
        };
        match link.outcomes.recv_timeout(max) {
            Ok(outcome) => self.plan.settle(Instant::now(), outcome),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => Some(self.lost()),
        }
    }

    /// The request thread is gone: plain polling from here on.
    fn lost(&mut self) -> Shift {
        self.link = None;
        self.plan = Plan { mode: Mode::Poll("watcher_gone"), ..Plan::new(false) };
        Shift { mode: self.plan.mode, rooms: 0, error: None, retry: None }
    }
}

fn outcome(answer: Result<Option<api::WatchResponse>, BotError>) -> Outcome {
    match answer {
        Ok(Some(resp)) => {
            let mut rooms = resp.changed;
            rooms.extend(resp.errors.into_keys());
            Outcome::Watched(rooms)
        }
        Ok(None) => Outcome::Unsupported,
        Err(err) => Outcome::Failed(err.to_string()),
    }
}

/// host-core's HTTP client with a read timeout sized for the watch — its
/// default (120 s) would let a relay that stopped answering hold the request
/// thread, and with it the loop's belief that a watch is in flight.
struct WatchTransport;

impl api::Transport for WatchTransport {
    fn send(
        &self, base: &str, method: &str, path_qs: &str, body: Option<&[u8]>, extra_headers: &[(&str, &str)],
    ) -> api::Result<native_mls_host::http::Response> {
        Ok(native_mls_host::http::request_with_timeouts(
            base, method, path_qs, body, extra_headers, CONNECT_TIMEOUT, Duration::from_millis(WAIT_MS.into()) + TIMEOUT_MARGIN,
        )?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(rooms: &[&str]) -> Vec<String> { rooms.iter().map(|r| r.to_string()).collect() }
    fn ms(n: u64) -> Duration { Duration::from_millis(n) }

    /// Switched off, every round reads every room and no watch is ever due.
    #[test]
    fn off_is_plain_polling() {
        let t0 = Instant::now();
        let mut plan = Plan::new(false);
        assert_eq!(plan.mode(), Mode::Poll("disabled"));
        for i in 0..5 {
            assert_eq!(plan.sweep(t0 + ms(200 * i)), Sweep::Full);
            assert!(!plan.due(t0 + ms(200 * i)));
        }
        let mut watch = RelayWatch::off();
        assert!(watch.arm(t0, || vec![("family".into(), 4)]).is_none());
        let started = Instant::now();
        assert!(watch.wait(ms(30)).is_none());
        assert!(started.elapsed() >= ms(30), "off: the wait is the plain sleep");
        assert_eq!(watch.sweep(Instant::now()), Sweep::Full);
    }

    /// A round reads every room unless a watch covered the wait before it.
    #[test]
    fn rounds_read_only_what_the_watch_names_while_one_covers_the_wait() {
        let t0 = Instant::now();
        let mut plan = Plan::new(true);
        // First round: nothing covered anything yet.
        assert_eq!(plan.sweep(t0), Sweep::Full);
        assert!(plan.due(t0));
        plan.sent(t0, names(&["a", "b"]));
        assert!(!plan.due(t0 + ms(5000)), "one watch at a time");
        // In flight, no answer: only rooms the watch does not carry.
        let quiet = plan.sweep(t0 + ms(200));
        assert!(!quiet.reads("a") && !quiet.reads("b"), "{quiet:?}");
        assert!(quiet.reads("new-room"), "a room the watch does not carry is read every round");
        // The answer names b (and a refused room): the next round reads those.
        let shift = plan.settle(t0 + ms(3000), Outcome::Watched(names(&["b", "gone"]))).expect("mode change");
        assert_eq!((shift.mode, shift.rooms, shift.retry), (Mode::Watch, 2, None));
        let named = plan.sweep(t0 + ms(3000));
        assert!(named.reads("b") && named.reads("gone") && !named.reads("a"), "{named:?}");
        // The next watch goes out at the end of that round; hints are spent.
        assert!(plan.due(t0 + ms(3001)));
        plan.sent(t0 + ms(3001), names(&["a", "b"]));
        let after = plan.sweep(t0 + ms(3201));
        assert!(!after.reads("a") && !after.reads("b"), "{after:?}");
        // A wait that ran out says nothing changed and is not a mode change.
        assert_eq!(plan.settle(t0 + ms(15_001), Outcome::Watched(Vec::new())), None);
        assert!(matches!(plan.sweep(t0 + ms(15_001)), Sweep::Hinted { .. }));
    }

    /// Between two watches (the minimum gap) no watch covers the wait, so the
    /// rounds in the gap are full ones — the old cadence, never a blind spot.
    #[test]
    fn the_gap_between_two_watches_is_polled() {
        let t0 = Instant::now();
        let mut plan = Plan::new(true);
        assert_eq!(plan.sweep(t0), Sweep::Full);
        plan.sent(t0, names(&["a"]));
        // Answers at once (rows were already there).
        plan.settle(t0 + ms(50), Outcome::Watched(names(&["a"])));
        assert!(plan.sweep(t0 + ms(50)).reads("a"));
        assert!(!plan.due(t0 + ms(60)), "no second watch within MIN_GAP of the first");
        assert_eq!(plan.sweep(t0 + ms(260)), Sweep::Full);
        assert_eq!(plan.sweep(t0 + ms(460)), Sweep::Full);
        assert!(!plan.due(t0 + ms(999)));
        assert!(plan.due(t0 + MIN_GAP));
    }

    /// The safety net: every room at least once per SAFETY_SWEEP, watch or not.
    #[test]
    fn safety_sweep_reads_every_room() {
        let t0 = Instant::now();
        let mut plan = Plan::new(true);
        assert_eq!(plan.sweep(t0), Sweep::Full);
        let mut fulls = 0;
        let mut at = t0;
        // 150 s of quiet 12 s waits, a round every 200 ms.
        while at < t0 + Duration::from_secs(150) {
            if plan.due(at) {
                plan.sent(at, names(&["a"]));
            }
            at += ms(200);
            if plan.flight.is_some_and(|sent| at.duration_since(sent) >= Duration::from_millis(WAIT_MS.into())) {
                plan.settle(at, Outcome::Watched(Vec::new()));
            }
            if plan.sweep(at) == Sweep::Full {
                fulls += 1;
            }
        }
        assert_eq!(fulls, 2, "one full round per {SAFETY_SWEEP:?} and none in between");
    }

    /// An old relay: plain polling, asked again after REPROBE.
    #[test]
    fn an_old_relay_is_polled_and_reprobed() {
        let t0 = Instant::now();
        let mut plan = Plan::new(true);
        assert_eq!(plan.sweep(t0), Sweep::Full);
        plan.sent(t0, names(&["a"]));
        let shift = plan.settle(t0 + ms(20), Outcome::Unsupported).expect("mode change");
        assert_eq!((shift.mode, shift.retry), (Mode::Poll("unsupported"), Some(REPROBE)));
        for i in 1..10 {
            assert_eq!(plan.sweep(t0 + ms(200 * i)), Sweep::Full, "round {i}");
            assert!(!plan.due(t0 + ms(200 * i)));
        }
        assert!(!plan.due(t0 + REPROBE));
        assert!(plan.due(t0 + ms(20) + REPROBE));
        // Still unsupported: no second log line.
        plan.sent(t0 + ms(20) + REPROBE, names(&["a"]));
        assert_eq!(plan.settle(t0 + ms(40) + REPROBE, Outcome::Unsupported), None);
    }

    /// An error: plain polling, retried on the relay backoff; an answer
    /// resets the backoff and switches back.
    #[test]
    fn an_error_falls_back_and_backs_off() {
        let t0 = Instant::now();
        let mut plan = Plan::new(true);
        assert_eq!(plan.sweep(t0), Sweep::Full);
        plan.sent(t0, names(&["a"]));
        let first = plan.settle(t0, Outcome::Failed("io error: reset".into())).expect("mode change");
        assert_eq!((first.mode, first.retry, first.error.as_deref()), (Mode::Poll("error"), Some(relay_backoff(1)), Some("io error: reset")));
        assert_eq!(plan.sweep(t0 + ms(200)), Sweep::Full);
        assert!(!plan.due(t0 + ms(400)), "backoff 500 ms");
        // MIN_GAP still applies on top of the first backoff step.
        assert!(!plan.due(t0 + ms(600)));
        let mut at = t0 + MIN_GAP;
        for attempt in 2..=8u32 {
            assert!(plan.due(at), "attempt {attempt}");
            plan.sent(at, names(&["a"]));
            assert_eq!(plan.settle(at, Outcome::Failed("x".into())), None, "same mode: logged once");
            assert_eq!(plan.sweep(at + ms(1)), Sweep::Full);
            assert!(!plan.due(at + relay_backoff(attempt).max(MIN_GAP) - ms(1)));
            at += relay_backoff(attempt).max(MIN_GAP);
        }
        assert_eq!(relay_backoff(8), native_mls_host::room::RELAY_BACKOFF_MAX);
        plan.sent(at, names(&["a"]));
        let back = plan.settle(at + ms(10), Outcome::Watched(Vec::new())).expect("mode change");
        assert_eq!(back.mode, Mode::Watch);
        assert!(plan.due(at + MIN_GAP), "an answer clears the backoff");
    }

    /// A watch that never answers stops counting as cover after its wait and
    /// margin; a failed read forces the next round to be a full one.
    #[test]
    fn an_overdue_watch_and_a_failed_read_force_full_rounds() {
        let t0 = Instant::now();
        let mut plan = Plan::new(true);
        assert_eq!(plan.sweep(t0), Sweep::Full);
        plan.sent(t0, names(&["a"]));
        let limit = Duration::from_millis(WAIT_MS.into()) + TIMEOUT_MARGIN;
        assert!(matches!(plan.sweep(t0 + limit), Sweep::Hinted { .. }));
        assert_eq!(plan.sweep(t0 + limit + ms(1)), Sweep::Full);
        assert_eq!(plan.sweep(t0 + limit + ms(201)), Sweep::Full);
        assert!(!plan.due(t0 + limit + ms(201)), "still one request at a time");

        let mut plan = Plan::new(true);
        assert_eq!(plan.sweep(t0), Sweep::Full);
        plan.sent(t0, names(&["a"]));
        plan.force_full();
        assert_eq!(plan.sweep(t0 + ms(200)), Sweep::Full);
        assert!(matches!(plan.sweep(t0 + ms(400)), Sweep::Hinted { .. }), "once");
    }

    /// The point of the thread: while a watch blocks for seconds, the loop's
    /// wait still returns after `max`, and an answer ends it early.
    #[test]
    fn a_blocked_watch_never_holds_the_loop_past_its_wait() {
        let (release, gate) = mpsc::channel::<()>();
        let mut watch = RelayWatch::spawn(move |targets| {
            let _ = gate.recv_timeout(Duration::from_secs(30));
            Outcome::Watched(targets.iter().map(|(room, _)| room.clone()).collect())
        });
        assert_eq!(watch.sweep(Instant::now()), Sweep::Full);
        assert!(watch.arm(Instant::now(), || vec![("family".into(), 7)]).is_none());
        for _ in 0..3 {
            let started = Instant::now();
            assert!(watch.wait(ms(100)).is_none());
            let took = started.elapsed();
            assert!(took >= ms(100) && took < ms(400), "the wait is the loop's own interval: {took:?}");
            assert!(!watch.sweep(Instant::now()).reads("family"), "covered by the watch in flight");
        }
        // The relay answers: the wait ends at once and the room is read.
        release.send(()).expect("release");
        let started = Instant::now();
        let shift = watch.wait(Duration::from_secs(5)).expect("first answer switches the mode");
        assert!(started.elapsed() < Duration::from_secs(2), "woken by the answer");
        assert_eq!((shift.mode, shift.rooms), (Mode::Watch, 1));
        assert_eq!((watch.mode().name(), watch.mode().label()), ("watch", "watch"));
        assert_eq!((Mode::Poll("starting").label(), Mode::Poll("error").label()), ("starting", "poll"));
        assert!(watch.sweep(Instant::now()).reads("family"));
    }

    /// At most `WATCH_MAX_ROOMS` go into one request; the rest stay uncovered
    /// (read every round). No rooms, no request.
    #[test]
    fn arm_caps_the_room_list_and_skips_an_empty_one() {
        let (seen_tx, seen) = mpsc::channel();
        let mut watch = RelayWatch::spawn(move |targets| {
            let _ = seen_tx.send(targets.len());
            Outcome::Watched(Vec::new())
        });
        let now = Instant::now();
        assert_eq!(watch.sweep(now), Sweep::Full);
        assert!(watch.arm(now, Vec::new).is_none());
        assert!(watch.plan.flight.is_none(), "nothing to wait on");
        let many: Vec<(String, i64)> = (0..api::WATCH_MAX_ROOMS + 3).map(|i| (format!("r{i:02}"), 0)).collect();
        assert!(watch.arm(now, || many).is_none());
        assert_eq!(seen.recv_timeout(Duration::from_secs(5)), Ok(api::WATCH_MAX_ROOMS));
        watch.wait(Duration::from_secs(5));
        let sweep = watch.sweep(Instant::now());
        assert!(!sweep.reads("r00") && sweep.reads(&format!("r{}", api::WATCH_MAX_ROOMS)), "{sweep:?}");
    }

    /// The relay's answer as the loop sees it: changed and refused rooms are
    /// both read; a plain 404 is an old relay; anything else is an error.
    #[test]
    fn relay_answers_map_to_outcomes() {
        let mut resp = api::WatchResponse { changed: names(&["a"]), ..Default::default() };
        resp.errors.insert("gone".into(), "no_such_room".into());
        assert_eq!(outcome(Ok(Some(resp))), Outcome::Watched(names(&["a", "gone"])));
        assert_eq!(outcome(Ok(None)), Outcome::Unsupported);
        assert!(matches!(outcome(Err(BotError::Status { status: 401 })), Outcome::Failed(_)));
    }

    /// The thread ending (its side of the channel gone) is plain polling, said once.
    #[test]
    fn a_dead_request_thread_is_plain_polling() {
        let mut watch = RelayWatch::spawn(|_| panic!("request thread dies"));
        assert_eq!(watch.sweep(Instant::now()), Sweep::Full);
        assert!(watch.arm(Instant::now(), || vec![("family".into(), 1)]).is_none());
        let shift = watch.wait(Duration::from_secs(5)).expect("said once");
        assert_eq!(shift.mode, Mode::Poll("watcher_gone"));
        assert_eq!(watch.sweep(Instant::now()), Sweep::Full);
        assert!(watch.arm(Instant::now(), || vec![("family".into(), 1)]).is_none());
        assert!(watch.wait(ms(10)).is_none());
    }
}
