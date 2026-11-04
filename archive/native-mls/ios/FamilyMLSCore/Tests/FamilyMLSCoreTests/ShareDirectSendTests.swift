// #669 공유 확장 직접 송신(ShareDirectSend.swift + ShareHandoff 조각 표시·임대) — #664 결정의 검증 가능 형태:
// D-A4 문턱(8 MiB / 24 MiB, prefix) · D-A3 표시 뒤 앱 claim 은 나머지만 · D-A5 queued 는 맡기지 않음·refused 는 닫고 계속 ·
// D-A1 폴백 사유마다 표시 없이 멈추고 그 조각부터 앱에 · 임대 안에서는 앱이 건너뛰고 지나면 이어받음.
import XCTest
@testable import FamilyMLSCore

final class ShareDirectSendTests: XCTestCase {
    private var temp: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let mib = 1024 * 1024

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("share-direct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func store() -> ShareHandoffStore { ShareHandoffStore(container: temp) }

    private func file(_ name: String, bytes: Int = 10) throws -> URL {
        let dir = temp.appendingPathComponent("in-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// 글 + 파일 2개 맡김(이름 = "0-a.jpg", "1-b.jpg").
    private func commit(text: String? = "hi", files: Int = 2, id: String = "item") throws -> ShareHandoff.Item {
        let urls = try (0..<files).map { try file("\(["a", "b", "c", "d"][$0]).jpg") }
        return try store().commit(scope: "s1", room: "family", text: text, files: urls, now: t0, id: id)
    }

    private func item(text: String? = "hi", files: [String]) -> ShareHandoff.Item {
        ShareHandoff.Item(id: "x", createdAt: t0, scope: "s1", room: "family", text: text, files: files)
    }

    private static func sent(_ seq: Int64) -> SendOutcome { .sent(clientId: "c\(seq)", seq: seq, duplicate: false) }

    /// 조각 → 결과 표. 없는 조각은 보냈다고 친다.
    private final class ScriptedSender: ShareDirectSending {
        var script: [ShareHandoff.Piece: Result<SendOutcome, Error>]
        var calls: [ShareHandoff.Piece] = []
        init(_ script: [ShareHandoff.Piece: Result<SendOutcome, Error>] = [:]) { self.script = script }
        func send(_ piece: ShareHandoff.Piece) async throws -> SendOutcome {
            calls.append(piece)
            return try script[piece]?.get() ?? ShareDirectSendTests.sent(Int64(calls.count))
        }
    }

    // MARK: - D-A4 계획

    func testPlanTextIsAlwaysDirectAndFilesWithinTheFileThresholdFollow() {
        let sizes = ["0-a": 8 * mib, "1-b": 8 * mib + 1, "2-c": 10]
        let plan = ShareDirectSend.plan(item(files: ["0-a", "1-b", "2-c"])) { sizes[$0] }
        XCTAssertEqual(plan.direct, [.text, .file("0-a")], "exactly 8 MiB is still direct; the first oversize file defers")
        XCTAssertEqual(plan.deferred, [.file("1-b"), .file("2-c")], "everything after the first deferred piece stays in order for the app")
    }

    func testPlanBatchCapIsAPrefixOfTheFiles() {
        let plan = ShareDirectSend.plan(item(text: nil, files: ["0-a", "1-b", "2-c", "3-d"])) { _ in 8 * mib }
        XCTAssertEqual(plan.direct, [.file("0-a"), .file("1-b"), .file("2-c")], "3 × 8 MiB = 24 MiB fits")
        XCTAssertEqual(plan.deferred, [.file("3-d")])
    }

    func testPlanUnknownFileSizeDefersFromThere() {
        let plan = ShareDirectSend.plan(item(files: ["0-a", "1-b"])) { $0 == "0-a" ? nil : 10 }
        XCTAssertEqual(plan.direct, [.text])
        XCTAssertEqual(plan.deferred, [.file("0-a"), .file("1-b")])
    }

    func testPlanTextOnlyAndEmpty() {
        XCTAssertEqual(ShareDirectSend.plan(item(files: [])) { _ in nil }, ShareDirectSend.Plan(direct: [.text]))
        XCTAssertEqual(ShareDirectSend.plan(item(text: nil, files: [])) { _ in nil }, ShareDirectSend.Plan())
    }

    // MARK: - 실행·표시 (D-A3·D-A5)

    func testAllPiecesSentAreMarkedAndNothingIsLeftForTheApp() async throws {
        let committed = try commit()
        let plan = ShareDirectSend.plan(committed) { ShareHandoffStore.fileSize(self.store().fileURL(committed, $0)) }
        XCTAssertEqual(plan.direct.count, 3)
        let sender = ScriptedSender()
        let report = await ShareDirectSend.run(plan: plan, item: committed.id, store: store(), sender: sender)
        XCTAssertEqual(report.sent, [.text, .file("0-a.jpg"), .file("1-b.jpg")])
        XCTAssertNil(report.stopped)
        XCTAssertFalse(report.needsApp)
        XCTAssertEqual(store().handledPieces(committed.id), [.text: .sent, .file("0-a.jpg"): .sent, .file("1-b.jpg"): .sent])
        let claimed = store().claim(committed.id)
        XCTAssertEqual(claimed?.isEmpty, true, "the app finds nothing left to send")
    }

    func testQueuedPieceCountsAsHandledSoTheAppDoesNotResendIt() async throws {
        let committed = try commit(files: 1)
        let sender = ScriptedSender([.file("0-a.jpg"): .success(.queued(clientId: "q"))])
        let report = await ShareDirectSend.run(plan: ShareDirectSend.plan(committed) { _ in 10 }, item: committed.id, store: store(), sender: sender)
        XCTAssertEqual(report.sent, [.text])
        XCTAssertEqual(report.queued, [.file("0-a.jpg")])
        XCTAssertFalse(report.needsApp, "outbox already holds the bytes — handing off would duplicate")
        XCTAssertEqual(store().handledPieces(committed.id)[.file("0-a.jpg")], .queued)
    }

    func testRefusedPieceIsClosedAndSendingContinuesWithTheNext() async throws {
        let committed = try commit(files: 1)
        let sender = ScriptedSender([.text: .failure(RelayError.refused(code: "too_large", status: 413))])
        let report = await ShareDirectSend.run(plan: ShareDirectSend.plan(committed) { _ in 10 }, item: committed.id, store: store(), sender: sender)
        XCTAssertEqual(report.refused, [ShareDirectSend.Refusal(piece: .text, status: 413, code: "too_large")])
        XCTAssertEqual(report.sent, [.file("0-a.jpg")], "the refusal does not stop the file")
        XCTAssertNil(report.stopped)
        XCTAssertFalse(report.needsApp)
        XCTAssertEqual(store().handledPieces(committed.id), [.text: .refused, .file("0-a.jpg"): .sent])
        XCTAssertEqual(store().claim(committed.id)?.isEmpty, true, "the app never retries a permanent refusal")
    }

    func testFallbackErrorsStopWithoutMarkingAndLeaveThatPieceOnForTheApp() async throws {
        let errors: [(String, Error)] = [
            ("not_joined", SyncError.notJoined),
            ("halted: removed", SyncError.halted("removed")),
            ("registration_pending", SyncError.registrationPending),
            ("cas_retry_exhausted", SyncError.casRetryExhausted),
            ("lock_timeout", StateStoreError.lockTimeout("family")),
            ("network", RelayError.network("offline")),
            ("unauthorized", RelayError.unauthorized),
            ("unreadable", ShareHandoff.Failure.unreadable(name: "0-a.jpg")),
        ]
        for (index, (expected, error)) in errors.enumerated() {
            let committed = try commit(id: "item-\(index)")
            let sender = ScriptedSender([.file("0-a.jpg"): .failure(error)])
            let report = await ShareDirectSend.run(plan: ShareDirectSend.plan(committed) { _ in 10 }, item: committed.id, store: store(), sender: sender)
            XCTAssertEqual(report.sent, [.text], expected)
            XCTAssertEqual(report.stopped, expected)
            XCTAssertEqual(report.remaining, [.file("0-a.jpg"), .file("1-b.jpg")], "\(expected): the failed piece and everything after it go to the app")
            XCTAssertEqual(sender.calls, [.text, .file("0-a.jpg")], "\(expected): nothing after the failure is attempted")
            XCTAssertEqual(store().handledPieces(committed.id), [.text: .sent], "\(expected): the failed piece carries no marker")
            let claimed = store().claim(committed.id)
            XCTAssertNil(claimed?.text, expected)
            XCTAssertEqual(claimed?.files, ["0-a.jpg", "1-b.jpg"], expected)
        }
    }

    func testDeferredPiecesAreAppendedToRemaining() async throws {
        let committed = try commit()
        let sizes = ["0-a.jpg": 10, "1-b.jpg": ShareDirectSend.maxDirectFileBytes + 1]
        let plan = ShareDirectSend.plan(committed) { sizes[$0] }
        XCTAssertEqual(plan.deferred, [.file("1-b.jpg")])
        let report = await ShareDirectSend.run(plan: plan, item: committed.id, store: store(), sender: ScriptedSender())
        XCTAssertEqual(report.sent, [.text, .file("0-a.jpg")])
        XCTAssertEqual(report.remaining, [.file("1-b.jpg")])
        XCTAssertTrue(report.needsApp)
        XCTAssertEqual(store().claim(committed.id)?.files, ["1-b.jpg"])
    }

    func testClaimAfterOneOfTwoFilesWasSentReturnsOnlyTheOther() throws {
        let committed = try commit()
        store().markPiece(committed.id, .file("0-a.jpg"), .sent)
        let claimed = store().claim(committed.id)
        XCTAssertEqual(claimed?.text, "hi")
        XCTAssertEqual(claimed?.files, ["1-b.jpg"])
        XCTAssertEqual(try Data(contentsOf: store().fileURL(claimed!, "1-b.jpg")).count, 10, "the remaining file is still readable")
    }

    func testReleaseAfterPartialSendKeepsOnlyTheRemainingPiece() throws {
        let committed = try commit()
        store().markPiece(committed.id, .text, .sent)
        var remaining = store().claim(committed.id)!
        remaining.files.removeFirst()   // 앱이 첫 파일을 보냈다
        store().release(remaining)
        let again = store().pending(scope: "s1", now: t0)
        XCTAssertEqual(again.count, 1)
        XCTAssertNil(again[0].text)
        XCTAssertEqual(again[0].files, ["1-b.jpg"])
        XCTAssertEqual(store().handledPieces(committed.id), [:], "release rewrites item.json from the remaining pieces; markers are spent")
    }

    func testMarkersWithUnknownContentAreIgnored() throws {
        let committed = try commit()
        try Data("later".utf8).write(to: temp.appendingPathComponent(ShareHandoff.directoryName).appendingPathComponent(committed.id)
            .appendingPathComponent("sent-text"))
        XCTAssertEqual(store().handledPieces(committed.id), [:])
        XCTAssertEqual(store().claim(committed.id)?.text, "hi")
    }

    // MARK: - 임대

    func testLeaseHidesTheItemFromTheAppUntilItExpiresOrEnds() throws {
        let committed = try commit()
        XCTAssertTrue(store().beginSending(committed.id, now: t0))
        XCTAssertEqual(store().pending(scope: "s1", now: t0.addingTimeInterval(10)), [], "the extension is sending")
        XCTAssertEqual(store().pending(scope: "s1", now: t0.addingTimeInterval(ShareHandoff.sendingLease - 1)), [])
        XCTAssertEqual(store().pending(scope: "s1", now: t0.addingTimeInterval(ShareHandoff.sendingLease)), [committed],
                       "the extension died — the app takes over")
        store().endSending(committed.id)
        XCTAssertEqual(store().pending(scope: "s1", now: t0.addingTimeInterval(10)), [committed])
    }

    func testBeginSendingOnAFinishedItemFailsClosed() {
        XCTAssertFalse(store().beginSending("nope", now: t0))
    }

    func testPiecesOfAnItemAreTextThenFilesInOrder() {
        XCTAssertEqual(ShareHandoff.Piece.all(of: item(files: ["0-a", "1-b"])), [.text, .file("0-a"), .file("1-b")])
        XCTAssertEqual(ShareHandoff.Piece.all(of: item(text: nil, files: ["0-a"])), [.file("0-a")])
    }
}
