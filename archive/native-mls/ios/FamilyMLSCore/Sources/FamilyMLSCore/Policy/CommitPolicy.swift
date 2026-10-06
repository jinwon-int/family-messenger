//! CommitPolicy — pure port of `archive/native-mls/bot/src/policy.rs` (iOS L3 lane).
//!
//! SKELETON ONLY (disk-first step 1, family-messenger#276 owner directive 2026-10-06):
//! types + signatures + TODO bodies. Implementation lands in the next commit,
//! vector-backed by `archive/native-mls/tests/fixtures/commit-policy-vectors.json`
//! (L2-owned fixture; read-only from tests).
//! Semantics summary: `archive/native-mls/ios/NOTES-L3.md`.
//!
//! Contract (frozen by #273; see `archive/native-mls/ios/CONTRACTS.md`):
//! - roster frame: `u32le count ‖ ∙( u32le idLen ‖ id ‖ 32B key )`; truncated → nil
//! - stage report: four sections — adds / removes / updates / path
//! - roster_after = sorted-unique(roster − removes + adds)
//! - check_commit(roster, committer, outer?) → expected roster | Refusal{reason, detail}

import Foundation

/// Refusal tokens — must match policy.rs byte-for-byte (vectors key on these strings).
public enum CommitRefusalReason: String, Sendable, CaseIterable {
    case committerPath = "committer_path"
    case committerMismatch = "committer_mismatch"
    case committerNotMember = "committer_not_member"
    case unexpectedUpdateProposal = "unexpected_update_proposal"
    case addAlreadyMember = "add_already_member"
    case addDuplicate = "add_duplicate"
    case removeNotMember = "remove_not_member"
    case removeDuplicate = "remove_duplicate"
    case addRemoveOverlap = "add_remove_overlap"
    case outerInnerMismatch = "outer_inner_mismatch"
}

/// Verdict failure: refusal token + human-readable detail.
public struct CommitRefusal: Error, Equatable, Sendable {
    public let reason: CommitRefusalReason
    public let detail: String

    public init(reason: CommitRefusalReason, detail: String) {
        self.reason = reason
        self.detail = detail
    }
}

/// One roster member as framed in the roster blob.
/// TODO(port): swap for the RelayTypes member type if signatures align; kept local so the
/// policy surface stays decoupled from RelayTypes (which this lane must not edit).
public struct PolicyMember: Equatable, Sendable {
    public let id: String
    /// 32 bytes.
    public let key: Data

    public init(id: String, key: Data) {
        self.id = id
        self.key = key
    }
}

/// Parsed stage report — exactly four sections: adds / removes / updates / path.
public struct StageReport: Equatable, Sendable {
    public let adds: [String]
    public let removes: [String]
    public let updates: [String]
    public let path: String

    public init(adds: [String], removes: [String], updates: [String], path: String) {
        self.adds = adds
        self.removes = removes
        self.updates = updates
        self.path = path
    }
}

public enum CommitPolicy {
    /// policy.rs roster-frame parse: `u32le count ‖ ∙( u32le idLen ‖ id ‖ 32B key )`.
    /// Truncated or malformed input → `nil` (Rust: truncation → None).
    public static func parseRosterFrame(_ data: Data) -> [PolicyMember]? {
        fatalError("TODO: port from policy.rs (vector-backed, next commit)")
    }

    /// policy.rs parse_stage_report: parse the four-section report text.
    /// Malformed input → `nil`.
    public static func parseStageReport(_ text: String) -> StageReport? {
        fatalError("TODO: port from policy.rs (vector-backed, next commit)")
    }

    /// policy.rs roster_after: `sorted-unique(roster − removes + adds)`.
    public static func rosterAfter(_ roster: [PolicyMember], report: StageReport) -> [PolicyMember] {
        fatalError("TODO: port from policy.rs (vector-backed, next commit)")
    }

    /// policy.rs check_commit: `(roster, committer, outer?) → expected roster | Refusal`.
    /// `outer` is the outer proposal's report (update-proposal path); `nil` for plain commits.
    public static func checkCommit(
        roster: [PolicyMember],
        committer: String,
        outer: StageReport?
    ) -> Result<[PolicyMember], CommitRefusal> {
        fatalError("TODO: port check_commit from policy.rs (vector-backed, next commit)")
    }
}
