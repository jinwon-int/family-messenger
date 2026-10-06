// CommitPolicy 벡터·와이어 테스트 — tests/fixtures/commit-policy-vectors.json(#261 web / #263 rust 공유) 기반 (#276 L3).
// fixture는 Swift 패키지 밖(archive/native-mls/tests/fixtures/)에 있어 #filePath에서 저장소 루트로
// 올라가며, 못 찾으면 탐색한 경로 전체를 실패 메시지에 나열한다.
// 정책 판정은 id만 사용(PolicyMember.key는 전달만 됨) — fixture의 roster/outer가 키 없는 id라서
// roster 프레임 인코딩 시 결정적 합성 키를 채우고, report 섹션의 64-hex 키는 그대로 디코딩해 쓴다.

import XCTest
@testable import FamilyMLSCore

final class PolicyTests: XCTestCase {

    // MARK: - fixture model

    private struct FixtureVector {
        let name: String
        let roster: [String]
        let committer: String
        let report: StageReport
        let outer: [String]?
        let ok: Bool
        let expected: [String]?
        let reason: String?
    }

    // MARK: - fixture loading (#filePath walk-up)

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "PolicyTests.fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func fixtureURL() throws -> URL {
        let relative = "archive/native-mls/tests/fixtures/commit-policy-vectors.json"
        var dir = URL(fileURLWithPath: #filePath)
        var searched: [String] = []
        for _ in 0..<10 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent(relative)
            searched.append(candidate.path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        XCTFail("commit-policy-vectors.json not found — searched:\n\(searched.joined(separator: "\n"))")
        throw fixtureError("fixture not found")
    }

    /// JSON 항목을 id 문자열로 정규화 — "id" 또는 ["id", …] 쌍 모두 허용.
    private func ids(_ raw: Any?) -> [String]? {
        guard let array = raw as? [Any] else { return nil }
        var out: [String] = []
        for entry in array {
            if let s = entry as? String { out.append(s) }
            else if let pair = entry as? [Any], let s = pair.first as? String { out.append(s) }
            else { return nil }
        }
        return out
    }

    private func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }

    private func hexKey32(_ hex: String, _ context: String) throws -> [UInt8] {
        let chars = Array(hex.utf8)
        guard chars.count == 64 else { throw fixtureError("\(context): key must be 64 hex chars") }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for i in stride(from: 0, to: 64, by: 2) {
            guard let hi = hexValue(chars[i]), let lo = hexValue(chars[i + 1]) else {
                throw fixtureError("\(context): invalid hex")
            }
            bytes.append(hi << 4 | lo)
        }
        return bytes
    }

    /// fixture에 키가 없는 멤버용 결정적 32B 합성 키(정책 판정에는 미사용).
    private func syntheticKey(_ id: String) -> [UInt8] {
        let b = Array(id.utf8)
        return (0..<32).map { i in b.isEmpty ? UInt8(i) : b[i % b.count] &+ UInt8((i * 7) % 251) }
    }

    private func stageReport(_ raw: Any?, name: String) throws -> StageReport {
        let sections: [String: [Any]]
        if let dict = raw as? [String: Any] {
            sections = ["adds": dict["adds"] as? [Any] ?? [],
                        "removes": dict["removes"] as? [Any] ?? [],
                        "updates": dict["updates"] as? [Any] ?? [],
                        "path": dict["path"] as? [Any] ?? []]
        } else if let arr = raw as? [Any], arr.count == 4 {
            let keys = ["adds", "removes", "updates", "path"]
            sections = Dictionary(uniqueKeysWithValues: zip(keys, arr.map { $0 as? [Any] ?? [] }))
        } else if raw == nil || raw is NSNull {
            sections = ["adds": [], "removes": [], "updates": [], "path": []]
        } else {
            throw fixtureError("[\(name)] unsupported report shape")
        }
        func members(_ key: String) throws -> [PolicyMember] {
            try sections[key]!.map { entry in
                if let s = entry as? String { return PolicyMember(id: s, key: syntheticKey(s)) }
                guard let pair = entry as? [Any], let id = pair.first as? String else {
                    throw fixtureError("[\(name)] \(key) entry is not [id, key]")
                }
                let keyHex = pair.count > 1 ? pair[1] as? String : nil
                let key = try keyHex.map { try hexKey32($0, "[\(name)] \(key) \(id)") } ?? syntheticKey(id)
                return PolicyMember(id: id, key: key)
            }
        }
        return StageReport(adds: try members("adds"), removes: try members("removes"),
                           updates: try members("updates"), path: try members("path"))
    }

    private func loadVectors() throws -> [FixtureVector] {
        let data = try Data(contentsOf: try fixtureURL())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any],
                                 "fixture root must be an object")
        let rawVectors = try XCTUnwrap(root["vectors"] as? [[String: Any]],
                                       "fixture must have a vectors array")
        return try rawVectors.enumerated().map { idx, raw in
            let name = (raw["name"] as? String) ?? "vector[\(idx)]"
            let roster = try XCTUnwrap(ids(raw["roster"]), "[\(name)] roster ids")
            let committer = try XCTUnwrap(raw["committer"] as? String, "[\(name)] committer")
            let report = try stageReport(raw["report"], name: name)
            let expect = try XCTUnwrap(raw["expect"] as? [String: Any], "[\(name)] expect")
            let ok = try XCTUnwrap((expect["ok"] as? NSNumber)?.boolValue, "[\(name)] expect.ok")
            return FixtureVector(name: name, roster: roster, committer: committer, report: report,
                                 outer: ids(raw["outer"]), ok: ok,
                                 expected: ids(expect["expected"]),
                                 reason: expect["reason"] as? String)
        }
    }

    // MARK: - wire encoding helpers

    private func u32le(_ v: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
         UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
    }

    private func framedMember(id: String, key: [UInt8]) -> [UInt8] {
        precondition(key.count == 32, "member key must be 32B")
        let idBytes = Array(id.utf8)
        return u32le(idBytes.count) + idBytes + key
    }

    private func framedList(_ members: [(String, [UInt8])]) -> [UInt8] {
        u32le(members.count) + members.flatMap { framedMember(id: $0.0, key: $0.1) }
    }

    private func encodeReport(_ r: StageReport) -> [UInt8] {
        func list(_ ms: [PolicyMember]) -> [UInt8] {
            u32le(ms.count) + ms.flatMap { framedMember(id: $0.id, key: $0.key) }
        }
        return list(r.adds) + list(r.removes) + list(r.updates) + list(r.path)
    }

    // MARK: - vector-backed behavior

    func testFixtureVectors_CheckCommit() throws {
        let vectors = try loadVectors()
        XCTAssertEqual(vectors.count, 14, "shared fixture must have 14 vectors")
        for v in vectors {
            let result = CommitPolicy.checkCommit(report: v.report, roster: v.roster,
                                                  committer: v.committer, outer: v.outer)
            switch result {
            case .success(let expected):
                XCTAssertTrue(v.ok, "[\(v.name)] unexpected success (want \(v.reason ?? "ok"))")
                if let want = v.expected {
                    XCTAssertEqual(expected, want, "[\(v.name)] expected roster mismatch")
                }
            case .failure(let refusal):
                XCTAssertFalse(v.ok, "[\(v.name)] unexpected refusal \(refusal.reason.rawValue): \(refusal.detail)")
                XCTAssertEqual(refusal.reason.rawValue, v.reason, "[\(v.name)] refusal token mismatch")
                XCTAssertFalse(refusal.detail.isEmpty, "[\(v.name)] refusal detail must not be empty")
            }
        }
    }

    func testFixtureRosterFrame_ParsesPerVector() throws {
        for v in try loadVectors() {
            let frame = Data(framedList(v.roster.map { ($0, syntheticKey($0)) }))
            let parsed = try XCTUnwrap(CommitPolicy.parseRosterFrame(frame),
                                       "[\(v.name)] roster frame must parse")
            XCTAssertEqual(parsed.map(\.id), v.roster, "[\(v.name)] roster ids")
            XCTAssertTrue(parsed.allSatisfy { $0.key.count == 32 }, "[\(v.name)] keys must be 32B")
        }
    }

    func testFixtureStageReport_ParsesPerVector() throws {
        for v in try loadVectors() {
            let data = Data(encodeReport(v.report))
            let parsed = try XCTUnwrap(CommitPolicy.parseStageReport(data),
                                       "[\(v.name)] stage report must parse")
            XCTAssertEqual(parsed, v.report, "[\(v.name)] stage report round-trip")
        }
    }

    // MARK: - wire edge cases

    func testRosterFrame_RejectsTruncation() {
        let frame = framedList([("owner-pc1", syntheticKey("owner-pc1")),
                                ("owner-pc2", syntheticKey("owner-pc2"))])
        for cut in [1, 4, 10, frame.count - 1] where cut > 0 {
            XCTAssertNil(CommitPolicy.parseRosterFrame(Data(frame.prefix(cut))),
                         "truncated at \(cut) bytes must be nil")
        }
        XCTAssertNil(CommitPolicy.parseRosterFrame(Data()), "empty input must be nil")
    }

    func testRosterFrame_RejectsTrailingBytes() {
        let frame = framedList([("owner-pc1", syntheticKey("owner-pc1"))])
        XCTAssertNil(CommitPolicy.parseRosterFrame(Data(frame + [0])))
        XCTAssertNil(CommitPolicy.parseRosterFrame(Data(frame + [0, 0, 0, 1])))
    }

    func testRosterFrame_CountLargerThanPayloadRejected() {
        var frame = u32le(5)
        frame += framedMember(id: "owner-pc1", key: syntheticKey("owner-pc1"))
        XCTAssertNil(CommitPolicy.parseRosterFrame(Data(frame)),
                     "count claiming more members than the payload must be nil")
    }

    func testStageReport_RejectsTrailingAndTruncation() {
        let report = StageReport(
            adds: [PolicyMember(id: "newcomer", key: syntheticKey("newcomer"))],
            removes: [PolicyMember(id: "owner-pc2", key: syntheticKey("owner-pc2"))],
            updates: [],
            path: [PolicyMember(id: "owner-pc1", key: syntheticKey("owner-pc1"))])
        let data = encodeReport(report)
        XCTAssertNil(CommitPolicy.parseStageReport(Data(data + [0])), "trailing byte must be nil")
        XCTAssertNil(CommitPolicy.parseStageReport(Data(data.prefix(data.count - 1))),
                     "truncation must be nil")
    }

    func testStageReport_AllEmptySectionsParse() throws {
        let parsed = try XCTUnwrap(CommitPolicy.parseStageReport(Data(repeating: 0, count: 16)),
                                   "4 empty framed lists must parse")
        XCTAssertEqual(parsed, StageReport(adds: [], removes: [], updates: [], path: []))
    }

    func testRefusalTokenContract() {
        XCTAssertEqual(CommitRefusalReason.allCases.count, 10, "10 shared refusal tokens")
        XCTAssertEqual(Set(CommitRefusalReason.allCases.map(\.rawValue)).count, 10,
                       "rawValues must be unique")
    }
}
