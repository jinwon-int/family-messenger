//! Host-neutral room rules (#366 slice 2a), moved out of `native-mls-bot`'s
//! session loop so every Rust host applies a room's events the same way:
//!
//! - [`guarded`]: run one MLS operation with rollback (review 2 B-H1/B-H3).
//! - [`apply_commit`]: the #263 two-step commit application — stage, check the
//!   roster delta with [`policy::check_commit`] (plus the relay's outer roster
//!   when the commit is the page's latest epoch), then merge or discard.
//! - [`history_gap`]: the #268 pruned-history rule.
//! - [`is_transient`] / [`relay_backoff`]: the #392 relay-retry rules.
//! - [`poll`] (#366 slice 2b): one round of a room's sync state machine over a
//!   [`RoomHost`] — ack, GET, gap, then each event in order.
//! - [`send_application`] (#366 slice 2c): encrypt → reserve the dedup key →
//!   persist → POST over a [`SendHost`], with the 409 outcomes a host replays
//!   or skips.
//!
//! The crate still does not link the MLS facade: a host adapts its group
//! object to [`MlsGroup`]. Transport, logging, halt markers, state files and
//! what to do with a decrypted message stay with the host — these functions
//! only decide and sequence.
use crate::api::{self, EventPost, EventResponse, EventsResponse, RelayError, StoredRow};
use crate::http::HttpError;
use crate::policy::{self, Refusal, StageReport};
use std::time::Duration;

/// The MLS group operations the room rules need. `Err(())` is a facade
/// rejection: the facade retires its device on any failed operation ("never
/// reuse uncertain state"), which is why [`guarded`] snapshots first.
pub trait MlsGroup {
    /// An exported copy of the whole group state. Hosts that hold key material
    /// in it should wipe it on drop (the bot uses `zeroize::Zeroizing`).
    type Snapshot;
    fn snapshot(&self) -> Result<Self::Snapshot, ()>;
    /// Replace the (possibly retired) live state with `snapshot`.
    fn restore(&mut self, snapshot: &Self::Snapshot) -> Result<(), ()>;
    /// Authenticate a commit and return the facade's format-2 stage report.
    fn stage_commit(&mut self, commit: &[u8]) -> Result<Vec<u8>, ()>;
    fn merge_staged(&mut self) -> Result<(), ()>;
    /// Drop the staged commit and keep the epoch (pure in the facade).
    fn discard_staged(&mut self);
    /// The framed current roster (`policy::parse_roster` input).
    fn members(&self) -> Result<Vec<u8>, ()>;
    /// Join from a Welcome.
    fn join(&mut self, welcome: &[u8]) -> Result<(), ()>;
    /// Decrypt one application event: `(sender identity, plaintext)`. The
    /// host's adapter owns the facade framing (room id, AAD client_id).
    fn decrypt(&mut self, ciphertext: &[u8]) -> Result<(Vec<u8>, Vec<u8>), ()>;
    /// Encrypt one application message at the current epoch (advances this
    /// device's sender ratchet). The adapter owns the framing and the AAD
    /// client_id (the bot binds its device identity — review H1).
    fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, ()>;
}

/// Run one MLS operation with rollback (review 2 B-H1/B-H3): the facade
/// retires the device on any rejected operation, so the pre-operation
/// snapshot is restored on failure and the caller reports and skips the
/// event (`Ok(Err(()))`). A snapshot that cannot be taken or restored is a
/// hard stop — the device is already retired and nothing short of a
/// re-enrollment helps.
pub fn guarded<G: MlsGroup, T>(
    group: &mut G, op: impl FnOnce(&mut G) -> Result<T, ()>,
) -> Result<Result<T, ()>, RelayError> {
    let snapshot = group.snapshot().map_err(|_| RelayError::Local("state snapshot before operation"))?;
    match op(group) {
        Ok(value) => Ok(Ok(value)),
        Err(()) => group
            .restore(&snapshot)
            .map(|()| Err(()))
            .map_err(|_| RelayError::Local("state rollback after rejected operation")),
    }
}

/// What [`apply_commit`] did with one foreign commit.
#[derive(Debug)]
pub enum CommitOutcome {
    /// The facade rejected the stage or the merge (a poison commit): the group
    /// was rolled back, the cursor may move past the event.
    Rejected,
    /// Merged. `members` is the expected post-commit roster; `outer_checked`
    /// says whether the relay's tracked roster took part in the check.
    Applied { report: StageReport, members: Vec<String>, outer_checked: bool },
    /// The policy refused the delta: the staged commit was discarded and the
    /// group stays at its epoch. Hosts halt the room (#263).
    Refused(Refusal),
}

/// The relay's tracked (outer) roster, when `ev` is the commit that produced
/// the page's epoch — the only commit the page's `members` describe (#261).
pub fn outer_roster(ev: &StoredRow, page: &EventsResponse) -> Option<Vec<String>> {
    (ev.epoch + 1 == page.epoch)
        .then(|| page.members.as_ref().map(|m| m.iter().map(|x| x.device.clone()).collect()))
        .flatten()
}

/// #263 two-step application of a foreign commit (the human client's #261
/// rule): stage (authenticate + roster delta report), check the delta against
/// this group's roster and — when this commit is the page's latest epoch —
/// against the relay's enforced roster, then merge. A facade rejection is
/// rolled back ([`CommitOutcome::Rejected`]); a policy refusal discards the
/// staged commit ([`CommitOutcome::Refused`]).
pub fn apply_commit<G: MlsGroup>(
    group: &mut G, ev: &StoredRow, page: &EventsResponse,
) -> Result<CommitOutcome, RelayError> {
    let report = match guarded(group, |g| g.stage_commit(&ev.bytes))? {
        Ok(report) => report,
        Err(()) => return Ok(CommitOutcome::Rejected),
    };
    let outer = outer_roster(ev, page);
    let verdict = match (policy::parse_stage_report(&report),
                         group.members().ok().and_then(|f| policy::parse_roster(&f))) {
        (None, _) => Err(Refusal { reason: "report_format", detail: format!("{} bytes", report.len()) }),
        (_, None) => Err(Refusal { reason: "roster_unavailable", detail: String::new() }),
        (Some(parsed), Some(roster)) => {
            let ids: Vec<String> = roster.into_iter().map(|m| m.id).collect();
            policy::check_commit(&parsed, &ids, &ev.device, outer.as_deref()).map(|expected| (parsed, expected))
        }
    };
    match verdict {
        Ok((report, members)) => match guarded(group, |g| g.merge_staged())? {
            Ok(()) => Ok(CommitOutcome::Applied { report, members, outer_checked: outer.is_some() }),
            Err(()) => Ok(CommitOutcome::Rejected),
        },
        Err(refusal) => {
            group.discard_staged();
            Ok(CommitOutcome::Refused(refusal))
        }
    }
}

/// `Some((first missing seq, last missing seq))` when a joined device's
/// cursor lies below the relay's oldest retained seq minus one (#268). An
/// unjoined device has no history to lose — events before its Welcome are
/// not its to read — and `first_seq == 0` is an empty room or an older relay.
pub fn history_gap(joined: bool, cursor: i64, first_seq: i64) -> Option<(i64, i64)> {
    (joined && first_seq > 0 && first_seq > cursor.saturating_add(1)).then(|| (cursor + 1, first_seq - 1))
}

/// One room's sync position (#366 2b) — what [`poll`] reads and moves. The
/// group itself, persistence and per-host extras (echo counters, retry
/// queues, modes) stay with the host.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RoomSync {
    pub room: String,
    /// Highest seq seen (processed or skipped).
    pub cursor: i64,
    /// The relay's room epoch as of the last page.
    pub epoch: i64,
    pub joined: bool,
    /// Whether a Welcome may be joined (a watch room — negative control —
    /// never joins, B-H3).
    pub joinable: bool,
    /// Group state moved since the host last persisted it.
    pub dirty: bool,
    /// Cursor the relay may prune up to (what the host has durably processed);
    /// sent as `?ack=` once joined (B-H4).
    pub acked: i64,
    /// Last ack the relay accepted; equal acks are not resent.
    pub ack_sent: i64,
    /// The relay refused an ack (removal, room reset): stop acking, keep reading.
    pub ack_disabled: bool,
    /// Refused commit or pruned history: neither read nor acked any more.
    pub halted: bool,
}

/// What [`poll`] tells the host to log (the bot prints these as JSON lines).
#[derive(Debug)]
pub enum SyncEvent<'a> {
    /// A refused ack disabled acking (400 bad_ack / 403 not_a_member).
    AckRefused { ack: i64, status: u16, code: &'a str },
    Joined { epoch: i64, seq: i64 },
    /// A Welcome that is not ours to act on (already joined, or a watch room).
    WelcomeIgnored { seq: i64, joined: bool },
    /// A poison Welcome/commit the facade rejected; the group was rolled back.
    Rejected { seq: i64, kind: &'a str, bytes: usize },
    CommitApplied { ev: &'a StoredRow, report: &'a StageReport, members: &'a [String], outer_checked: bool },
    Application { ev: &'a StoredRow, sender: &'a [u8], bytes: usize },
    Undecryptable { seq: i64, bytes: usize },
}

/// Why [`poll`] halted the room. `RoomSync::halted` is already set; the host
/// reports it and makes it durable (the bot writes a marker file).
#[derive(Debug)]
pub enum Halt<'a> {
    /// The policy refused a foreign commit (#263); its staged state was discarded.
    Refused { ev: &'a StoredRow, refusal: Refusal },
    /// The relay pruned seqs `from..=to` this joined device never read (#268).
    /// Nothing of the page was processed: cursor and epoch are unchanged.
    Gap { first_seq: i64, relay_epoch: i64, from: i64, to: i64 },
}

/// One room's sync position and group, as [`poll`] and [`send_application`] reach them.
pub trait RoomAccess {
    type Group<'g>: MlsGroup where Self: 'g;
    fn sync(&mut self) -> &mut RoomSync;
    /// The room's group, borrowed for one operation.
    fn group(&mut self) -> Self::Group<'_>;
}

/// A host of one room for [`poll`].
pub trait RoomHost: RoomAccess {
    /// GET the next events page (`after` = cursor, `ack` when due).
    fn fetch(&mut self, room: &str, after: i64, ack: Option<i64>) -> Result<EventsResponse, RelayError>;
    fn report(&mut self, event: SyncEvent<'_>);
    fn halt(&mut self, halt: Halt<'_>) -> Result<(), RelayError>;
    /// A decrypted application message from another device, in page order.
    fn application(&mut self, ev: &StoredRow, sender: Vec<u8>, plaintext: Vec<u8>) -> Result<(), RelayError>;
    /// An event this device posted (MLS never processes its own messages; a
    /// pending own commit merges here).
    fn own_event(&mut self, ev: &StoredRow) -> Result<(), RelayError>;
    /// The page was processed and the room is joined (replay queued sends).
    fn after_page(&mut self) -> Result<(), RelayError>;
}

/// One sync round for one room (relay-app `sync()` · bot `poll_room` order):
///
/// ```text
/// halted → nothing · ack what is durable (joined only) → GET events
///   404 no_such_room → nothing · 400 bad_ack / 403 not_a_member on an ack → stop acking
/// → pruned-history gap → halt (before anything moves)
/// → epoch = page epoch → per event: cursor = max(cursor, seq)
///   own → host · welcome → join (joinable, not joined) or ignore
///   commit (joined) → apply_commit · application (joined) → decrypt → host
/// → joined → host.after_page
/// ```
///
/// Events before our Welcome are not ours to read and are skipped.
pub fn poll<H: RoomHost>(host: &mut H, own: &str) -> Result<(), RelayError> {
    let sync = host.sync();
    if sync.halted {
        return Ok(());
    }
    let ack = (sync.joined && !sync.ack_disabled && sync.acked > sync.ack_sent).then_some(sync.acked);
    let (room, after) = (sync.room.clone(), sync.cursor);
    let page = match host.fetch(&room, after, ack) {
        Ok(page) => page,
        // A room that does not exist yet (its founding commit is not posted):
        // nothing to see.
        Err(RelayError::Api { status: 404, code }) if code == "no_such_room" => return Ok(()),
        Err(RelayError::Api { status, code })
            if ack.is_some() && ((status == 400 && code == "bad_ack") || (status == 403 && code == "not_a_member")) =>
        {
            host.sync().ack_disabled = true;
            host.report(SyncEvent::AckRefused { ack: ack.unwrap_or_default(), status, code: &code });
            return Ok(());
        }
        Err(err) => return Err(err),
    };
    if let Some(acked) = ack {
        host.sync().ack_sent = acked;
    }
    let sync = host.sync();
    if let Some((from, to)) = history_gap(sync.joined, sync.cursor, page.first_seq) {
        sync.halted = true;
        return host.halt(Halt::Gap { first_seq: page.first_seq, relay_epoch: page.epoch, from, to });
    }
    sync.epoch = page.epoch;
    for ev in &page.events {
        let sync = host.sync();
        sync.cursor = sync.cursor.max(ev.seq);
        if ev.device == own {
            host.own_event(ev)?;
            continue;
        }
        let (joinable, joined) = (sync.joinable, sync.joined);
        match ev.kind.as_str() {
            "welcome" if joinable && !joined => {
                let outcome = guarded(&mut host.group(), |g| g.join(&ev.bytes))?;
                let sync = host.sync();
                sync.dirty = true;
                match outcome {
                    Ok(()) => {
                        sync.joined = true;
                        host.report(SyncEvent::Joined { epoch: ev.epoch, seq: ev.seq });
                    }
                    Err(()) => host.report(SyncEvent::Rejected { seq: ev.seq, kind: "welcome", bytes: ev.bytes.len() }),
                }
            }
            "welcome" => {
                host.sync().dirty = true;
                host.report(SyncEvent::WelcomeIgnored { seq: ev.seq, joined });
            }
            "commit" if joined => {
                let outcome = apply_commit(&mut host.group(), ev, &page)?;
                let sync = host.sync();
                sync.dirty = true;
                match outcome {
                    CommitOutcome::Rejected => host.report(SyncEvent::Rejected { seq: ev.seq, kind: "commit", bytes: ev.bytes.len() }),
                    CommitOutcome::Applied { report, members, outer_checked } => {
                        host.report(SyncEvent::CommitApplied { ev, report: &report, members: &members, outer_checked });
                    }
                    CommitOutcome::Refused(refusal) => {
                        sync.halted = true;
                        host.halt(Halt::Refused { ev, refusal })?;
                    }
                }
            }
            "application" if joined => {
                let outcome = guarded(&mut host.group(), |g| g.decrypt(&ev.bytes))?;
                // Decrypting consumed receive keys (or rolled back a poison
                // event): either way that state belongs on disk.
                host.sync().dirty = true;
                match outcome {
                    Ok((sender, plaintext)) => {
                        host.report(SyncEvent::Application { ev, sender: &sender, bytes: plaintext.len() });
                        host.application(ev, sender, plaintext)?;
                    }
                    Err(()) => host.report(SyncEvent::Undecryptable { seq: ev.seq, bytes: ev.bytes.len() }),
                }
            }
            // Everything before our Welcome (commits that formed the group,
            // other members' applications) is not ours to read.
            _ => {}
        }
    }
    if host.sync().joined {
        host.after_page()?;
    }
    Ok(())
}

/// A host of one room for [`send_application`].
pub trait SendHost: RoomAccess {
    /// Reserve the relay's per-device dedup key for this send. Called after the
    /// encryption succeeded, before [`SendHost::persist`] — a restart must
    /// not hand out the same key twice (the bot: `<device>-echo-<n>`).
    fn reserve_client_id(&mut self) -> String;
    /// Make the group state (the advanced sender ratchet) and the reserved key
    /// durable. Runs before the ciphertext leaves the process (review 2 B-H2:
    /// a restart must never re-derive a sender generation that was sent).
    fn persist(&mut self) -> Result<(), RelayError>;
    fn post(&mut self, room: &str, post: &EventPost<'_>) -> Result<EventResponse, RelayError>;
}

/// What became of one [`send_application`].
#[derive(Debug)]
pub enum SendOutcome {
    /// The relay stored it (or recognised a duplicate POST: `response.duplicate`).
    Sent { client_id: String, response: EventResponse },
    /// 409 `cas_mismatch`: the room moved under us (a commit we have not seen).
    /// The host resynchronizes and replays the plaintext at the fresh epoch.
    Conflict { client_id: String, error: RelayError },
    /// 409 `client_id_reuse`: an earlier incarnation already delivered this
    /// key (state restored from a backup, for instance) — the relay has the
    /// message, the counter is now past it; move on.
    AlreadyDelivered { client_id: String, error: RelayError },
}

/// Send one application message to the room (bot `publish_echo` order):
/// encrypt at the current epoch → reserve the dedup key → mark dirty and
/// persist → POST with the room's epoch. Any other relay error is the
/// caller's; a failed encryption reserves nothing and persists nothing.
pub fn send_application<H: SendHost>(host: &mut H, own: &str, plaintext: &[u8]) -> Result<SendOutcome, RelayError> {
    // The bot's log name for this failure predates the move; kept for parity.
    let framed = host.group().encrypt(plaintext).map_err(|_| RelayError::Local("encrypt echo"))?;
    let client_id = host.reserve_client_id();
    host.sync().dirty = true;
    host.persist()?;
    let (room, epoch) = {
        let sync = host.sync();
        (sync.room.clone(), sync.epoch)
    };
    let post = EventPost {
        device: own,
        client_id: &client_id,
        kind: "application",
        epoch,
        revision: None,
        group_id: &room,
        targets: Vec::new(),
        members: Vec::new(),
        bytes: framed,
    };
    match host.post(&room, &post) {
        Ok(response) => Ok(SendOutcome::Sent { client_id, response }),
        Err(error @ RelayError::Api { status: 409, .. }) if api::error_code(&error) == Some("cas_mismatch") => {
            Ok(SendOutcome::Conflict { client_id, error })
        }
        Err(error @ RelayError::Api { status: 409, .. }) if api::error_code(&error) == Some("client_id_reuse") => {
            Ok(SendOutcome::AlreadyDelivered { client_id, error })
        }
        Err(error) => Err(error),
    }
}

/// #392: first wait after the relay could not be reached; doubles per
/// consecutive unreachable round up to `RELAY_BACKOFF_MAX`.
pub const RELAY_BACKOFF_FIRST: Duration = Duration::from_millis(500);
pub const RELAY_BACKOFF_MAX: Duration = Duration::from_secs(30);

/// #392: a relay that is restarting or briefly unreachable — connection
/// refused/reset/timeout, a response cut off mid-read, or a gateway's 502/503/504
/// — is worth waiting out. Everything else (the error envelope, policy
/// refusals, a malformed base URL, local MLS errors) is not.
pub fn is_transient(err: &RelayError) -> bool {
    match err {
        RelayError::Http(HttpError::Io(_) | HttpError::BadResponse(_)) => true,
        RelayError::Status { status } | RelayError::Api { status, .. } => matches!(status, 502..=504),
        _ => false,
    }
}

/// Wait before the `attempt`-th retry (1-based): 0.5 s, 1 s, 2 s … capped at 30 s.
pub fn relay_backoff(attempt: u32) -> Duration {
    RELAY_BACKOFF_FIRST.saturating_mul(1u32 << attempt.saturating_sub(1).min(16)).min(RELAY_BACKOFF_MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::MemberOwned;

    /// A scripted group: the roster is a plain id list, the stage report is
    /// whatever the test set, and `retired` models the facade retiring its
    /// device after a rejected operation.
    #[derive(Clone, Default)]
    struct FakeGroup {
        roster: Vec<String>,
        report: Vec<u8>,
        reject_stage: bool,
        reject_merge: bool,
        reject_restore: bool,
        reject_encrypt: bool,
        staged: bool,
        merged: u32,
        discarded: u32,
        retired: bool,
    }

    /// `policy::parse_roster` framing: `u32 LE len ‖ identity ‖ 32-byte key`.
    fn frame(out: &mut Vec<u8>, id: &str) {
        out.extend_from_slice(&(id.len() as u32).to_le_bytes());
        out.extend_from_slice(id.as_bytes());
        out.extend_from_slice(&[7u8; 32]);
    }

    fn roster_bytes(ids: &[&str]) -> Vec<u8> {
        let mut out = (ids.len() as u32).to_le_bytes().to_vec();
        for id in ids {
            frame(&mut out, id);
        }
        out
    }

    /// Format-2 stage report: four framed sections (adds, removes, updates, path).
    fn report(adds: &[&str], removes: &[&str], path: &[&str]) -> Vec<u8> {
        let mut out = Vec::new();
        for section in [adds, removes, &[], path] {
            out.extend_from_slice(&roster_bytes(section));
        }
        out
    }

    impl MlsGroup for FakeGroup {
        type Snapshot = FakeGroup;
        fn snapshot(&self) -> Result<FakeGroup, ()> { if self.retired { Err(()) } else { Ok(self.clone()) } }
        fn restore(&mut self, snapshot: &FakeGroup) -> Result<(), ()> {
            if self.reject_restore { return Err(()) }
            *self = snapshot.clone();
            Ok(())
        }
        fn stage_commit(&mut self, _commit: &[u8]) -> Result<Vec<u8>, ()> {
            if self.reject_stage { self.retired = true; return Err(()) }
            self.staged = true;
            Ok(self.report.clone())
        }
        fn merge_staged(&mut self) -> Result<(), ()> {
            if self.reject_merge { self.retired = true; return Err(()) }
            self.merged += 1;
            Ok(())
        }
        fn discard_staged(&mut self) { self.staged = false; self.discarded += 1; }
        fn members(&self) -> Result<Vec<u8>, ()> {
            let ids: Vec<&str> = self.roster.iter().map(String::as_str).collect();
            Ok(roster_bytes(&ids))
        }
        fn join(&mut self, welcome: &[u8]) -> Result<(), ()> {
            if welcome == b"poison" { self.retired = true; return Err(()) }
            Ok(())
        }
        fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, ()> {
            if self.reject_encrypt { return Err(()) }
            Ok([b"ct:".as_slice(), plaintext].concat())
        }
        /// `ok:<text>` decrypts to `(b"peer", text)`; anything else is rejected.
        fn decrypt(&mut self, ciphertext: &[u8]) -> Result<(Vec<u8>, Vec<u8>), ()> {
            match ciphertext.strip_prefix(b"ok:") {
                Some(text) => Ok((b"peer".to_vec(), text.to_vec())),
                None => { self.retired = true; Err(()) }
            }
        }
    }

    /// Test-only: a borrowed group is a group (what `RoomHost::group` lends).
    impl<T: MlsGroup> MlsGroup for &mut T {
        type Snapshot = T::Snapshot;
        fn snapshot(&self) -> Result<T::Snapshot, ()> { (**self).snapshot() }
        fn restore(&mut self, snapshot: &T::Snapshot) -> Result<(), ()> { (**self).restore(snapshot) }
        fn stage_commit(&mut self, commit: &[u8]) -> Result<Vec<u8>, ()> { (**self).stage_commit(commit) }
        fn merge_staged(&mut self) -> Result<(), ()> { (**self).merge_staged() }
        fn discard_staged(&mut self) { (**self).discard_staged() }
        fn members(&self) -> Result<Vec<u8>, ()> { (**self).members() }
        fn join(&mut self, welcome: &[u8]) -> Result<(), ()> { (**self).join(welcome) }
        fn decrypt(&mut self, ciphertext: &[u8]) -> Result<(Vec<u8>, Vec<u8>), ()> { (**self).decrypt(ciphertext) }
        fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, ()> { (**self).encrypt(plaintext) }
    }

    /// A host that serves scripted pages and records every callback.
    struct ScriptHost {
        sync: RoomSync,
        group: FakeGroup,
        pages: std::collections::VecDeque<Result<EventsResponse, RelayError>>,
        fetched: Vec<(i64, Option<i64>)>,
        log: Vec<String>,
        halts: Vec<String>,
        apps: Vec<(i64, String, String)>,
        own: Vec<i64>,
        after_pages: u32,
    }

    impl ScriptHost {
        fn new(joined: bool, cursor: i64, pages: Vec<Result<EventsResponse, RelayError>>) -> ScriptHost {
            ScriptHost {
                sync: RoomSync { room: "family".into(), cursor, epoch: 1, joined, joinable: true, ..RoomSync::default() },
                group: group(&["owner", "bot"], report(&["phone"], &[], &["owner"])),
                pages: pages.into(), fetched: Vec::new(), log: Vec::new(), halts: Vec::new(),
                apps: Vec::new(), own: Vec::new(), after_pages: 0,
            }
        }
    }

    impl RoomAccess for ScriptHost {
        type Group<'g> = &'g mut FakeGroup;
        fn sync(&mut self) -> &mut RoomSync { &mut self.sync }
        fn group(&mut self) -> &mut FakeGroup { &mut self.group }
    }

    impl RoomHost for ScriptHost {
        fn fetch(&mut self, room: &str, after: i64, ack: Option<i64>) -> Result<EventsResponse, RelayError> {
            assert_eq!(room, "family");
            self.fetched.push((after, ack));
            self.pages.pop_front().expect("a scripted page")
        }
        fn report(&mut self, event: SyncEvent<'_>) {
            self.log.push(match event {
                SyncEvent::AckRefused { ack, status, code } => format!("ack_refused {ack} {status} {code}"),
                SyncEvent::Joined { epoch, seq } => format!("joined {seq}@{epoch}"),
                SyncEvent::WelcomeIgnored { seq, joined } => format!("welcome_ignored {seq} {joined}"),
                SyncEvent::Rejected { seq, kind, .. } => format!("rejected {seq} {kind}"),
                SyncEvent::CommitApplied { ev, members, outer_checked, .. } => format!("commit_applied {} {} {outer_checked}", ev.seq, members.join(",")),
                SyncEvent::Application { ev, sender, bytes } => format!("application {} {} {bytes}", ev.seq, String::from_utf8_lossy(sender)),
                SyncEvent::Undecryptable { seq, .. } => format!("undecryptable {seq}"),
            });
        }
        fn halt(&mut self, halt: Halt<'_>) -> Result<(), RelayError> {
            assert!(self.sync.halted, "halted is set before the host is told");
            self.halts.push(match halt {
                Halt::Refused { ev, refusal } => format!("refused {} {}", ev.seq, refusal.reason),
                Halt::Gap { first_seq, from, to, .. } => format!("gap {first_seq} {from}..{to}"),
            });
            Ok(())
        }
        fn application(&mut self, ev: &StoredRow, sender: Vec<u8>, plaintext: Vec<u8>) -> Result<(), RelayError> {
            self.apps.push((ev.seq, String::from_utf8_lossy(&sender).into(), String::from_utf8_lossy(&plaintext).into()));
            Ok(())
        }
        fn own_event(&mut self, ev: &StoredRow) -> Result<(), RelayError> { self.own.push(ev.seq); Ok(()) }
        fn after_page(&mut self) -> Result<(), RelayError> { self.after_pages += 1; Ok(()) }
    }

    fn row(seq: i64, device: &str, kind: &str, epoch: i64, bytes: &[u8]) -> StoredRow {
        StoredRow {
            seq, device: device.into(), client_id: format!("c{seq}"), kind: kind.into(), epoch,
            bytes: bytes.to_vec(), sha256: String::new(), created_at: 0,
        }
    }

    fn events(epoch: i64, first_seq: i64, rows: Vec<StoredRow>) -> Result<EventsResponse, RelayError> {
        Ok(EventsResponse { epoch, revision: 0, events: rows, members: None, first_seq })
    }

    fn commit_row(device: &str, epoch: i64) -> StoredRow {
        StoredRow {
            seq: 5, device: device.into(), client_id: "c".into(), kind: "commit".into(), epoch,
            bytes: vec![1, 2, 3], sha256: String::new(), created_at: 0,
        }
    }

    fn page(epoch: i64, members: Option<&[&str]>) -> EventsResponse {
        EventsResponse {
            epoch, revision: 0, events: Vec::new(), first_seq: 0,
            members: members.map(|m| m.iter().map(|d| MemberOwned { device: (*d).into(), actor: (*d).into() }).collect()),
        }
    }

    fn group(roster: &[&str], report_bytes: Vec<u8>) -> FakeGroup {
        FakeGroup { roster: roster.iter().map(|s| (*s).into()).collect(), report: report_bytes, ..FakeGroup::default() }
    }

    #[test]
    fn guarded_restores_the_snapshot_after_a_rejection() {
        let mut g = group(&["bot"], Vec::new());
        g.reject_stage = true;
        let outcome = guarded(&mut g, |g| g.stage_commit(b"x")).expect("rollback ok");
        assert_eq!(outcome, Err(()));
        assert!(!g.retired, "the retired state was replaced by the snapshot");
    }

    #[test]
    fn guarded_fails_hard_when_rollback_fails() {
        let mut g = group(&["bot"], Vec::new());
        g.reject_stage = true;
        g.reject_restore = true;
        let err = guarded(&mut g, |g| g.stage_commit(b"x")).expect_err("hard stop");
        assert!(matches!(err, RelayError::Local("state rollback after rejected operation")));
        let mut retired = group(&["bot"], Vec::new());
        retired.retired = true;
        let err = guarded(&mut retired, |g| g.merge_staged()).expect_err("no snapshot");
        assert!(matches!(err, RelayError::Local("state snapshot before operation")));
    }

    #[test]
    fn apply_commit_merges_an_allowed_add_with_the_outer_roster() {
        let mut g = group(&["owner", "bot"], report(&["phone"], &[], &["owner"]));
        let outcome = apply_commit(&mut g, &commit_row("owner", 2), &page(3, Some(&["owner", "bot", "phone"]))).expect("ok");
        match outcome {
            CommitOutcome::Applied { report, members, outer_checked } => {
                assert_eq!(report.adds.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["phone"]);
                assert_eq!(members, ["bot", "owner", "phone"], "sorted roster after the add");
                assert!(outer_checked);
            }
            other => panic!("expected Applied, got {other:?}"),
        }
        assert_eq!(g.merged, 1);
    }

    #[test]
    fn apply_commit_skips_the_outer_check_for_an_older_epoch() {
        let mut g = group(&["owner", "bot"], report(&["phone"], &[], &["owner"]));
        // The page is two epochs ahead: its members do not describe this commit.
        let outcome = apply_commit(&mut g, &commit_row("owner", 2), &page(4, Some(&["owner"]))).expect("ok");
        assert!(matches!(outcome, CommitOutcome::Applied { outer_checked: false, .. }), "{outcome:?}");
    }

    #[test]
    fn apply_commit_refuses_a_committer_mismatch_and_discards() {
        let mut g = group(&["owner", "bot"], report(&["phone"], &[], &["owner"]));
        let outcome = apply_commit(&mut g, &commit_row("bot", 2), &page(3, None)).expect("ok");
        match outcome {
            CommitOutcome::Refused(refusal) => assert_eq!(refusal.reason, "committer_mismatch"),
            other => panic!("expected Refused, got {other:?}"),
        }
        assert_eq!((g.discarded, g.merged), (1, 0));
    }

    #[test]
    fn apply_commit_refuses_an_unreadable_report() {
        let mut g = group(&["owner", "bot"], vec![0, 0]);
        match apply_commit(&mut g, &commit_row("owner", 2), &page(3, None)).expect("ok") {
            CommitOutcome::Refused(refusal) => assert_eq!((refusal.reason, refusal.detail.as_str()), ("report_format", "2 bytes")),
            other => panic!("expected Refused, got {other:?}"),
        }
    }

    #[test]
    fn apply_commit_reports_poison_stage_and_merge_as_rejected() {
        let mut g = group(&["owner", "bot"], report(&[], &[], &["owner"]));
        g.reject_stage = true;
        assert!(matches!(apply_commit(&mut g, &commit_row("owner", 2), &page(3, None)).expect("ok"), CommitOutcome::Rejected));
        assert!(!g.retired);
        let mut g = group(&["owner", "bot"], report(&[], &[], &["owner"]));
        g.reject_merge = true;
        assert!(matches!(apply_commit(&mut g, &commit_row("owner", 2), &page(3, None)).expect("ok"), CommitOutcome::Rejected));
        assert!(!g.retired);
        assert_eq!(g.merged, 0);
    }

    #[test]
    fn poll_joins_then_reads_in_page_order() {
        let mut host = ScriptHost::new(false, 0, vec![events(2, 1, vec![
            row(1, "owner", "commit", 0, b"founding"),       // before our Welcome: skipped
            row(2, "owner", "application", 1, b"ok:early"),  // before our Welcome: skipped
            row(3, "owner", "welcome", 1, b"w"),
            row(4, "owner", "application", 2, b"ok:hello"),
            row(5, "bot", "application", 2, b"mine"),        // own echo
            row(6, "owner", "welcome", 2, b"w2"),            // re-invite after join: ignored
            row(7, "owner", "application", 2, b"forged"),
        ])]);
        poll(&mut host, "bot").expect("poll");
        assert_eq!(host.fetched, [(0, None)], "an unjoined device never acks");
        assert_eq!(host.log, ["joined 3@1", "application 4 peer 5", "welcome_ignored 6 true", "undecryptable 7"]);
        assert_eq!(host.apps, [(4, "peer".to_string(), "hello".to_string())]);
        assert_eq!(host.own, [5]);
        assert_eq!((host.sync.cursor, host.sync.epoch, host.sync.joined, host.sync.dirty), (7, 2, true, true));
        assert!(!host.group.retired, "the forged event was rolled back");
        assert_eq!(host.after_pages, 1);
    }

    #[test]
    fn poll_acks_only_new_durable_progress() {
        let mut host = ScriptHost::new(true, 10, vec![events(2, 1, vec![]), events(2, 1, vec![])]);
        host.sync.acked = 10;
        host.sync.ack_sent = 4;
        poll(&mut host, "bot").expect("first");
        poll(&mut host, "bot").expect("second");
        assert_eq!(host.fetched, [(10, Some(10)), (10, None)], "an accepted ack is not resent");
        assert_eq!(host.sync.ack_sent, 10);
    }

    #[test]
    fn poll_stops_acking_when_the_relay_refuses() {
        let mut host = ScriptHost::new(true, 10, vec![Err(RelayError::Api { status: 403, code: "not_a_member".into() })]);
        host.sync.acked = 10;
        poll(&mut host, "bot").expect("refused ack is not fatal");
        assert!(host.sync.ack_disabled);
        assert_eq!(host.log, ["ack_refused 10 403 not_a_member"]);
        assert_eq!(host.after_pages, 0);
        // Without an ack the same error is the caller's.
        let mut plain = ScriptHost::new(true, 10, vec![Err(RelayError::Api { status: 403, code: "not_a_member".into() })]);
        assert!(poll(&mut plain, "bot").is_err());
    }

    #[test]
    fn poll_treats_a_missing_room_as_empty() {
        let mut host = ScriptHost::new(false, 0, vec![Err(RelayError::Api { status: 404, code: "no_such_room".into() })]);
        poll(&mut host, "bot").expect("not yet founded");
        assert!(host.log.is_empty() && host.halts.is_empty());
        assert_eq!(host.after_pages, 0);
    }

    #[test]
    fn poll_halts_on_a_history_gap_before_moving() {
        let mut host = ScriptHost::new(true, 4, vec![events(9, 10, vec![row(10, "owner", "application", 9, b"ok:late")])]);
        poll(&mut host, "bot").expect("gap is reported, not an error");
        assert_eq!(host.halts, ["gap 10 5..9"]);
        assert_eq!((host.sync.cursor, host.sync.epoch, host.sync.halted), (4, 1, true), "nothing of the page moved");
        assert!(host.apps.is_empty());
        poll(&mut host, "bot").expect("halted");
        assert_eq!(host.fetched.len(), 1, "a halted room is never fetched again");
    }

    #[test]
    fn poll_halts_on_a_refused_commit_and_applies_an_allowed_one() {
        let mut host = ScriptHost::new(true, 0, vec![events(3, 1, vec![row(1, "owner", "commit", 2, b"add phone")])]);
        poll(&mut host, "bot").expect("applied");
        assert_eq!(host.log, ["commit_applied 1 bot,owner,phone false"]);
        assert_eq!(host.group.merged, 1);
        // The bot is not the MLS committer the report names: refused and halted.
        let mut host = ScriptHost::new(true, 0, vec![events(3, 1, vec![row(1, "bot2", "commit", 2, b"forged")])]);
        poll(&mut host, "bot").expect("refusal is reported, not an error");
        assert_eq!(host.halts, ["refused 1 committer_mismatch"]);
        assert!(host.sync.halted && host.sync.dirty);
        assert_eq!(host.group.discarded, 1);
    }

    #[test]
    fn poll_rejects_a_poison_welcome_without_joining() {
        let mut host = ScriptHost::new(false, 0, vec![events(1, 1, vec![row(1, "owner", "welcome", 1, b"poison")])]);
        poll(&mut host, "bot").expect("poll");
        assert_eq!(host.log, ["rejected 1 welcome"]);
        assert!(!host.sync.joined && !host.group.retired);
        assert_eq!(host.after_pages, 0, "not joined: no queued sends to replay");
    }

    /// A sender that records the order of reserve / persist / post.
    struct ScriptSender {
        sync: RoomSync,
        group: FakeGroup,
        steps: Vec<String>,
        counter: u64,
        reply: Option<Result<EventResponse, RelayError>>,
        posted: Vec<(String, String, i64, Vec<u8>)>,
    }

    impl ScriptSender {
        fn new(reply: Result<EventResponse, RelayError>) -> ScriptSender {
            ScriptSender {
                sync: RoomSync { room: "family".into(), epoch: 4, joined: true, ..RoomSync::default() },
                group: FakeGroup::default(), steps: Vec::new(), counter: 6, reply: Some(reply), posted: Vec::new(),
            }
        }
    }

    impl RoomAccess for ScriptSender {
        type Group<'g> = &'g mut FakeGroup;
        fn sync(&mut self) -> &mut RoomSync { &mut self.sync }
        fn group(&mut self) -> &mut FakeGroup { &mut self.group }
    }

    impl SendHost for ScriptSender {
        fn reserve_client_id(&mut self) -> String {
            self.counter += 1;
            self.steps.push(format!("reserve {}", self.counter));
            format!("bot-echo-{}", self.counter)
        }
        fn persist(&mut self) -> Result<(), RelayError> {
            assert!(self.sync.dirty, "the send marked the state dirty before persisting");
            self.steps.push("persist".into());
            self.sync.dirty = false;
            Ok(())
        }
        fn post(&mut self, room: &str, post: &EventPost<'_>) -> Result<EventResponse, RelayError> {
            self.steps.push("post".into());
            self.posted.push((room.into(), post.client_id.into(), post.epoch, post.bytes.clone()));
            assert_eq!((post.device, post.kind, post.group_id), ("bot", "application", "family"));
            self.reply.take().expect("one scripted reply")
        }
    }

    #[test]
    fn send_persists_before_the_ciphertext_leaves() {
        let mut host = ScriptSender::new(Ok(EventResponse { seq: 12, epoch: 4, revision: 0, duplicate: false }));
        match send_application(&mut host, "bot", b"hi").expect("sent") {
            SendOutcome::Sent { client_id, response } => assert_eq!((client_id.as_str(), response.seq), ("bot-echo-7", 12)),
            other => panic!("expected Sent, got {other:?}"),
        }
        assert_eq!(host.steps, ["reserve 7", "persist", "post"], "B-H2 order");
        assert_eq!(host.posted, [("family".to_string(), "bot-echo-7".to_string(), 4, b"ct:hi".to_vec())]);
    }

    #[test]
    fn send_reports_the_two_409s_and_passes_other_errors() {
        let conflict = RelayError::Api { status: 409, code: "cas_mismatch".into() };
        let mut host = ScriptSender::new(Err(conflict));
        assert!(matches!(send_application(&mut host, "bot", b"hi").expect("conflict is an outcome"),
                         SendOutcome::Conflict { ref client_id, .. } if client_id == "bot-echo-7"));
        let reuse = RelayError::Api { status: 409, code: "client_id_reuse".into() };
        let mut host = ScriptSender::new(Err(reuse));
        assert!(matches!(send_application(&mut host, "bot", b"hi").expect("reuse is an outcome"), SendOutcome::AlreadyDelivered { .. }));
        let mut host = ScriptSender::new(Err(RelayError::Api { status: 403, code: "not_a_member".into() }));
        assert!(matches!(send_application(&mut host, "bot", b"hi"), Err(RelayError::Api { status: 403, .. })));
        assert_eq!(host.steps, ["reserve 7", "persist", "post"], "persisted even when the POST fails");
    }

    #[test]
    fn send_reserves_nothing_when_encryption_fails() {
        let mut host = ScriptSender::new(Ok(EventResponse { seq: 1, epoch: 4, revision: 0, duplicate: false }));
        host.group.reject_encrypt = true;
        assert!(matches!(send_application(&mut host, "bot", b"hi"), Err(RelayError::Local("encrypt echo"))));
        assert!(host.steps.is_empty() && host.posted.is_empty());
        assert_eq!(host.counter, 6);
    }

    #[test]
    fn history_gap_rule() {
        assert_eq!(history_gap(true, 4, 10), Some((5, 9)));
        assert_eq!(history_gap(true, 4, 6), Some((5, 5)));
        assert_eq!(history_gap(true, 4, 5), None);
        assert_eq!(history_gap(true, 4, 1), None);
        assert_eq!(history_gap(true, 4, 0), None);
        assert_eq!(history_gap(false, 0, 10), None);
        assert_eq!(history_gap(true, i64::MAX, 10), None);
    }

    #[test]
    fn relay_retry_rules() {
        let reset = std::io::Error::from(std::io::ErrorKind::ConnectionReset);
        assert!(is_transient(&RelayError::Http(HttpError::Io(reset))));
        assert!(is_transient(&RelayError::Http(HttpError::BadResponse("eof"))));
        assert!(is_transient(&RelayError::Status { status: 503 }));
        assert!(is_transient(&RelayError::Api { status: 502, code: "bad_gateway".into() }));
        assert!(!is_transient(&RelayError::Http(HttpError::BadUrl)), "a bad base URL never heals");
        assert!(!is_transient(&RelayError::Api { status: 500, code: "internal".into() }));
        assert!(!is_transient(&RelayError::Local("state export rejected")));
        let waits: Vec<u64> = (1..=8).map(|n| relay_backoff(n).as_millis() as u64).collect();
        assert_eq!(waits, [500, 1000, 2000, 4000, 8000, 16000, 30000, 30000]);
        assert_eq!(relay_backoff(u32::MAX), RELAY_BACKOFF_MAX);
    }
}
