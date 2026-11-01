// #643 공유 확장 맡김(ShareHandoff.swift) — 확장이 쓰고 앱이 꺼내는 디스크 계약: 완성본만 보임 · 생성 순 · claim 1회성 ·
// claim 된 채 남은 것 폐기 · 24h 만료 · 다른 스코프 보존 → 만료 · 한도 검증 · 공유 대상 순서.
import XCTest
@testable import FamilyMLSCore

final class ShareHandoffTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func file(_ name: String, bytes: Int) throws -> URL {
        let dir = temp.appendingPathComponent("in-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func store() -> ShareHandoffStore { ShareHandoffStore(container: temp) }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testCommittedItemIsVisibleWithItsFilesInOrder() throws {
        let photo = try file("IMG 0001.HEIC", bytes: 10)
        let doc = try file("report.pdf", bytes: 20)
        let item = try store().commit(scope: "s1", room: "family", text: "  보세요\n", files: [photo, doc], now: t0, id: "a")
        XCTAssertEqual(item.text, "보세요", "trimmed")
        XCTAssertEqual(item.files, ["0-IMG 0001.HEIC", "1-report.pdf"])
        let pending = store().pending(scope: "s1", now: t0)
        XCTAssertEqual(pending, [item])
        XCTAssertEqual(try Data(contentsOf: store().fileURL(item, item.files[1])).count, 20)
    }

    func testPendingIsInCreationOrder() throws {
        let s = store()
        try s.commit(scope: "s1", room: "family", text: "둘", files: [], now: t0.addingTimeInterval(5), id: "b")
        try s.commit(scope: "s1", room: "family", text: "하나", files: [], now: t0, id: "z")
        XCTAssertEqual(s.pending(scope: "s1", now: t0.addingTimeInterval(10)).map(\.text), ["하나", "둘"])
    }

    func testStagingIsNeverVisibleAndOldStagingIsCleaned() throws {
        let s = store()
        let fresh = s.root.appendingPathComponent(".staging-\(Int(t0.timeIntervalSince1970))-x", isDirectory: true)
        let old = s.root.appendingPathComponent(".staging-\(Int(t0.timeIntervalSince1970) - 7200)-y", isDirectory: true)
        for dir in [fresh, old] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        XCTAssertEqual(s.pending(scope: "s1", now: t0), [], "staging is not a handoff")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "the extension may still be writing it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "an abandoned staging older than 1h is removed")
    }

    func testClaimSucceedsOnceAndHidesTheItem() throws {
        let s = store()
        let item = try s.commit(scope: "s1", room: "family", text: "한 번만", files: [], now: t0, id: "c")
        XCTAssertEqual(s.claim("c"), item)
        XCTAssertNil(s.claim("c"), "a second claim (another delivery path) gets nothing — no double send")
        XCTAssertEqual(s.pending(scope: "s1", now: t0), [], "claimed items are not pending")
        s.finish("c")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("c").path))
    }

    func testPendingLeavesClaimedDirectoriesButDiscardStaleClaimsRemovesThem() throws {
        let s = store()
        try s.commit(scope: "s1", room: "family", text: "보내는 중", files: [], now: t0, id: "d")
        XCTAssertNotNil(s.claim("d"))
        _ = s.pending(scope: "s1", now: t0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("d").path), "may be sending right now")
        XCTAssertEqual(s.discardStaleClaims(), 1, "left claimed by a crashed run — dropped, never resent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("d").path))
    }

    func testExpiredItemsAreRemovedWithoutBeingDelivered() throws {
        let s = store()
        try s.commit(scope: "s1", room: "family", text: "오래됨", files: [], now: t0, id: "e")
        try s.commit(scope: "s2", room: "family", text: "다른 서버, 오래됨", files: [], now: t0, id: "f")
        let later = t0.addingTimeInterval(ShareHandoff.lifetime + 1)
        XCTAssertEqual(s.pending(scope: "s1", now: later), [])
        for id in ["e", "f"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: s.root.appendingPathComponent(id).path), id)
        }
    }

    func testOtherScopeIsKeptUntilItExpires() throws {
        let s = store()
        let other = try s.commit(scope: "s2", room: "family", text: "다른 서버", files: [], now: t0, id: "g")
        XCTAssertEqual(s.pending(scope: "s1", now: t0), [])
        XCTAssertEqual(s.pending(scope: "s2", now: t0), [other], "switching back to that server still delivers it")
    }

    func testCorruptItemIsRemoved() throws {
        let s = store()
        let dir = s.root.appendingPathComponent("h", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("item.json"))
        XCTAssertEqual(s.pending(scope: "s1", now: t0), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testValidationRejectsEmptyTooManyAndTooLargeBeforeWritingAnything() throws {
        let s = store()
        XCTAssertThrowsError(try s.commit(scope: "s1", room: "family", text: " \n ", files: [], now: t0)) {
            XCTAssertEqual($0 as? ShareHandoff.Failure, .empty)
        }
        let many = try (0...ShareHandoff.maxAttachments).map { try file("p\($0).jpg", bytes: 1) }
        XCTAssertThrowsError(try s.commit(scope: "s1", room: "family", text: nil, files: many, now: t0)) {
            XCTAssertEqual($0 as? ShareHandoff.Failure, .tooManyAttachments(count: ShareHandoff.maxAttachments + 1, limit: ShareHandoff.maxAttachments))
        }
        let big = try file("big.mov", bytes: 11)
        XCTAssertThrowsError(try s.commit(scope: "s1", room: "family", text: nil, files: [big], maxFileBytes: 10, now: t0)) {
            XCTAssertEqual($0 as? ShareHandoff.Failure, .fileTooLarge(name: "big.mov", bytes: 11, limit: 10))
        }
        let empty = try file("empty.txt", bytes: 0)
        XCTAssertThrowsError(try s.commit(scope: "s1", room: "family", text: nil, files: [empty], now: t0)) {
            XCTAssertEqual($0 as? ShareHandoff.Failure, .fileTooLarge(name: "empty.txt", bytes: 0, limit: ShareHandoff.maxFileBytes()))
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: s.root.path)) ?? [], [], "nothing staged on rejection")
    }

    func testFileLimitFollowsTheSendPath() {
        XCTAssertEqual(ShareHandoff.maxFileBytes(fileV2: true), FileV2Format.maxFileBytes)
        XCTAssertEqual(ShareHandoff.maxFileBytes(fileV2: false), AttachmentFormat.maxBytes)
    }

    func testComposeTextJoinsTextAndLinksWithoutDuplicates() {
        let url = URL(string: "https://example.com/a?b=1")!
        XCTAssertEqual(ShareHandoff.composeText(["  제목  ", "", "제목"], urls: [url]), "제목\nhttps://example.com/a?b=1")
        XCTAssertEqual(ShareHandoff.composeText(["읽어 봐 https://example.com/a?b=1"], urls: [url]), "읽어 봐 https://example.com/a?b=1",
                       "Safari puts the address in the text — not appended twice")
        XCTAssertNil(ShareHandoff.composeText([" "], urls: []))
    }

    func testTargetsFollowTheListOrderAndSkipHaltedRooms() {
        let rooms = [
            RoomRecord(room: "family", epoch: 1, revision: 1, haltedReason: nil, displayOrder: 0),
            RoomRecord(room: "family-acc", epoch: 1, revision: 1, haltedReason: nil, displayOrder: 1),
            RoomRecord(room: "old", epoch: 1, revision: 1, haltedReason: "403", displayOrder: 2),
            RoomRecord(room: "work", epoch: 1, revision: 1, haltedReason: nil, displayOrder: 3),
        ]
        XCTAssertEqual(ShareHandoff.targets(rooms, saved: ["work", "old", "gone"]), ["work", "family", "family-acc"])
    }

    func testSafeNameStripsPathSeparatorsAndKeepsTheExtension() {
        XCTAssertEqual(ShareHandoffStore.safeName("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(ShareHandoffStore.safeName(""), "file")
        let long = String(repeating: "가", count: 120) + ".pdf"
        let safe = ShareHandoffStore.safeName(long)
        XCTAssertTrue(safe.hasSuffix(".pdf"))
        XCTAssertLessThanOrEqual(safe.count, 80)
    }
}
