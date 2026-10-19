//! Host-neutral room rules (#366 slice 2a), moved out of `native-mls-bot`'s
//! session loop so every Rust host applies a room's events the same way:
//!
//! - [`guarded`]: run one MLS operation with rollback (review 2 B-H1/B-H3).
//! - [`apply_commit`]: the #263 two-step commit application — stage, check the
//!   roster delta with [`policy::check_commit`] (plus the relay's outer roster
//!   when the commit is the page's latest epoch), then merge or discard.
//! - [`history_gap`]: the #268 pruned-history rule.
//! - [`is_transient`] / [`relay_backoff`]: the #392 relay-retry rules.
//!
//! The crate still does not link the MLS facade: a host adapts its group
//! object to [`MlsGroup`]. Logging, halt markers and state files stay with the
//! host — these functions only decide.
use crate::api::{EventsResponse, RelayError, StoredRow};
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
