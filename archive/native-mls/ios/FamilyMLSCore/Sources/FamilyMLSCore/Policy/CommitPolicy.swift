// 커밋 정책 — bot/src/policy.rs(#263)·web/commit-policy.js(#261)의 Swift 포트 (#276 L3).
// 계약(CONTRACTS.md / tests/fixtures/commit-policy-vectors.json):
//   - roster 프레임: u32le count ‖ 멤버마다 { u32le idLen ‖ id ‖ 32B key }. 잘림·잉여 바이트 모두 nil.
//   - stage report: adds / removes / updates / path 4개 프레임드 리스트를 이어 붙인 Data. 잉여 바이트 → nil.
//   - check_commit 성공값 = sorted-unique(roster − removes + adds).
//   - 검사 순서(policy.rs와 글자 그대로 동일): committer_path → committer_mismatch → committer_not_member
//     → unexpected_update_proposal → add_already_member → add_duplicate → remove_not_member
//     → remove_duplicate → add_remove_overlap → outer_inner_mismatch.
//   - refusal 토큰 10종은 web/rust 벡터와 공유(fixture `expect.reason` 문자열).
//   - outer == nil이면 내부 검사만 수행; 주어지면 sorted-unique 비교(순서·중복 무시).

import Foundation

public struct PolicyMember: Equatable {
    public let id: String
    public let key: [UInt8]  // 32B (MLS identity key 자리; 정책 판정에는 id만 사용)

    public init(id: String, key: [UInt8]) {
        self.id = id
        self.key = key
    }
}

public struct StageReport: Equatable {
    public let adds: [PolicyMember]
    public let removes: [PolicyMember]
    public let updates: [PolicyMember]
    public let path: [PolicyMember]

    public init(adds: [PolicyMember], removes: [PolicyMember], updates: [PolicyMember], path: [PolicyMember]) {
        self.adds = adds
        self.removes = removes
        self.updates = updates
        self.path = path
    }
}

/// 거부 사유 — rawValue가 web/rust와 공유하는 refusal 토큰 그 자체.
public enum CommitRefusalReason: String, CaseIterable {
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

public struct CommitRefusal: Equatable, Error {
    public let reason: CommitRefusalReason
    public let detail: String

    public init(reason: CommitRefusalReason, detail: String) {
        self.reason = reason
        self.detail = detail
    }
}

public enum CommitPolicy {
    // MARK: - wire parsing

    private static func readU32le(_ bytes: [UInt8], _ i: inout Int) -> UInt32? {
        guard i + 4 <= bytes.count else { return nil }
        let v = UInt32(bytes[i])
            | UInt32(bytes[i + 1]) << 8
            | UInt32(bytes[i + 2]) << 16
            | UInt32(bytes[i + 3]) << 24
        i += 4
        return v
    }

    /// `i` 위치에서 멤버 리스트 1개(u32le count + 멤버들)를 소비. 경계 초과·비UTF-8 id → nil.
    /// (입력 끝 도달 여부는 호출자가 검사 — stage report는 리스트 4개가 연접되므로.)
    private static func takeMemberList(_ bytes: [UInt8], _ i: inout Int) -> [PolicyMember]? {
        guard let count = readU32le(bytes, &i) else { return nil }
        // 멤버 1개는 최소 4(idLen)+1(id)+32(key)=37B. 비정상적으로 큰 count를 루프 전에 걷어냄.
        guard Int(count) <= (bytes.count - i - 4) / 37 else { return nil }
        var members: [PolicyMember] = []
        for _ in 0..<Int(count) {
            guard let idLen = readU32le(bytes, &i) else { return nil }
            let n = Int(idLen)
            guard i + n <= bytes.count else { return nil }
            guard let id = String(data: Data(bytes[i ..< i + n]), encoding: .utf8) else { return nil }
            i += n
            guard i + 32 <= bytes.count else { return nil }
            members.append(PolicyMember(id: id, key: Array(bytes[i ..< i + 32])))
            i += 32
        }
        return members
    }

    /// roster 프레임 파싱. 입력을 정확히 소비해야 하고, 잉여 바이트가 남으면 nil.
    public static func parseRosterFrame(_ data: Data) -> [PolicyMember]? {
        let bytes = [UInt8](data)
        var i = 0
        guard let members = takeMemberList(bytes, &i), i == bytes.count else { return nil }
        return members
    }

    /// stage report 파싱: adds/removes/updates/path 프레임드 리스트 4개 연접. 잉여 바이트 → nil.
    public static func parseStageReport(_ data: Data) -> StageReport? {
        let bytes = [UInt8](data)
        var i = 0
        guard let adds = takeMemberList(bytes, &i),
              let removes = takeMemberList(bytes, &i),
              let updates = takeMemberList(bytes, &i),
              let path = takeMemberList(bytes, &i),
              i == bytes.count
        else { return nil }
        return StageReport(adds: adds, removes: removes, updates: updates, path: path)
    }

    // MARK: - commit check

    /// policy.rs `check_commit` 포트. 성공 시 기대 roster(sorted-unique), 실패 시 CommitRefusal.
    /// 검사 순서는 벡터(#261/#263 공유 fixture)로 고정 — 바꾸면 fixture가 깨진다.
    public static func checkCommit(
        report: StageReport,
        roster: [String],
        committer: String,
        outer: [String]?
    ) -> Result<[String], CommitRefusal> {
        func refuse(_ reason: CommitRefusalReason, _ detail: String) -> Result<[String], CommitRefusal> {
            .failure(CommitRefusal(reason: reason, detail: detail))
        }
        // ① path는 정확히 1장 (0장 또는 2장 이상 → committer_path)
        guard report.path.count == 1 else {
            return refuse(.committerPath, "path must contain exactly one leaf, got \(report.path.count)")
        }
        // ② path leaf의 id == committer (릴레이 row와 MLS 커미터 불일치 방지)
        let pathId = report.path[0].id
        guard pathId == committer else {
            return refuse(.committerMismatch, "path leaf \(pathId) != committer \(committer)")
        }
        // ③ committer는 현재 roster 멤버
        let rosterSet = Set(roster)
        guard rosterSet.contains(committer) else {
            return refuse(.committerNotMember, "committer \(committer) is not a roster member")
        }
        // ④ 이 단계에서 update proposal은 허용되지 않음
        guard report.updates.isEmpty else {
            return refuse(.unexpectedUpdateProposal, "updates must be empty, got \(report.updates.map(\.id))")
        }
        let addIds = report.adds.map(\.id)
        let removeIds = report.removes.map(\.id)
        // ⑤ add 대상은 현재 멤버가 아니어야 함
        for id in addIds where rosterSet.contains(id) {
            return refuse(.addAlreadyMember, "add of current member \(id)")
        }
        // ⑥ add 중복 금지
        var seenAdds = Set<String>()
        for id in addIds where !seenAdds.insert(id).inserted {
            return refuse(.addDuplicate, "duplicate add \(id)")
        }
        // ⑦ remove 대상은 현재 멤버여야 함
        for id in removeIds where !rosterSet.contains(id) {
            return refuse(.removeNotMember, "remove of non-member \(id)")
        }
        // ⑧ remove 중복 금지
        var seenRemoves = Set<String>()
        for id in removeIds where !seenRemoves.insert(id).inserted {
            return refuse(.removeDuplicate, "duplicate remove \(id)")
        }
        // ⑨ add ∩ remove 금지 (⑤~⑧ 순서상 실제 입력에선 먼저 걸리지만 토큰·순서는 rust/web과 동일 유지)
        if let id = seenAdds.intersection(seenRemoves).sorted().first {
            return refuse(.addRemoveOverlap, "\(id) appears in both adds and removes")
        }
        // 기대 roster = sorted-unique(roster − removes + adds)
        var expectedSet = rosterSet
        expectedSet.subtract(seenRemoves)
        expectedSet.formUnion(seenAdds)
        let expected = expectedSet.sorted()
        // ⑩ outer가 주어지면 sorted-unique 비교 (순서·중복 무시)
        if let outer, Set(outer) != expectedSet {
            return refuse(.outerInnerMismatch, "outer roster does not match expected \(expected)")
        }
        return .success(expected)
    }
}
