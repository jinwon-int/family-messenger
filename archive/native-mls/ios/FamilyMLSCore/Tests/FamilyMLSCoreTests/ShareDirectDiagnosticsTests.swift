// #664 공유 확장 직접 송신 측정 기록(ShareDirectDiagnostics.swift) — 확장이 쓰고 앱의 「진단 기록 복사」가 읽는 디스크 계약:
// 시작 표시 → 결과 채움 · 최근 `keep` 건만 · 결과 없는 기록은 임대 안 `in-progress`, 지나면 `did-not-finish` · 쓰기/읽기 실패는 조용히 ·
// 식별자(글·파일 이름·방·기기)가 형식상 들어갈 자리가 없고 문자열 둘(빌드·멈춤 사유)은 쓸 때와 보일 때 걸러진다.
import XCTest
@testable import FamilyMLSCore

final class ShareDirectDiagnosticsTests: XCTestCase {
    private var temp: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("share-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func store() -> ShareDirectDiagnosticsStore { ShareDirectDiagnosticsStore(container: temp) }

    private func started(_ offset: TimeInterval = 0, pieces: Int = 3, deferred: Int = 1, bytes: Int = 2048) -> ShareDirectDiagnostics.Record {
        ShareDirectDiagnostics.Record(startedAt: t0.addingTimeInterval(offset), build: "116", pieces: pieces, deferred: deferred, bytes: bytes,
                                      footprintBefore: 18.44, limit: 120.04)
    }

    private func outcome(stopped: String? = nil) -> ShareDirectDiagnostics.Outcome {
        ShareDirectDiagnostics.Outcome(sent: 2, queued: 1, refused: 0, stopped: stopped, footprintAfter: 22, footprintPeak: 61.3, seconds: 12.34)
    }

    // MARK: - 시작 표시 → 결과

    func testStartedRecordIsOnDiskBeforeTheSendAndFinishFillsTheSameRecord() {
        let record = started()
        store().begin(record)
        XCTAssertEqual(store().records(), [record], "the marker is readable by another store instance (the app) before the send ends")
        XCTAssertNil(store().records().first?.outcome)

        store().finish(record, outcome())
        let all = store().records()
        XCTAssertEqual(all, [record.finished(outcome())], "finished in place — not a second record")
        XCTAssertEqual(all.first?.footprintBefore, 18.4, "MB are kept to one decimal")
        XCTAssertEqual(all.first?.outcome?.seconds, 12.3)
    }

    func testFinishCompletesItsOwnMarkerAndLeavesAnEarlierUnfinishedOne() {
        let killed = started(0)
        let second = started(300)
        store().begin(killed)
        store().begin(second)
        store().finish(second, outcome())
        XCTAssertEqual(store().records(), [killed, second.finished(outcome())], "the earlier marker stays unfinished")
    }

    func testFinishWithoutItsMarkerStillRecordsTheResult() throws {
        let record = started()
        store().begin(record)
        try FileManager.default.removeItem(at: store().file)   // 시작 표시가 사라졌다(쓰기 실패와 같은 상태)
        store().finish(record, outcome())
        XCTAssertEqual(store().records(), [record.finished(outcome())])
    }

    // MARK: - 개수 상한

    func testOnlyTheLastKeepRecordsStay() {
        let total = ShareDirectDiagnostics.keep + 5
        for index in 0..<total { store().begin(started(TimeInterval(index), pieces: index)) }
        let all = store().records()
        XCTAssertEqual(all.count, ShareDirectDiagnostics.keep)
        XCTAssertEqual(all.first?.pieces, 5, "the oldest five were dropped")
        XCTAssertEqual(all.last?.pieces, total - 1, "newest last")
        XCTAssertEqual(ShareDirectDiagnostics.keep, 20)
    }

    // MARK: - 「진단 기록 복사」 줄

    func testFinishedLineCarriesTheOsLogFieldsPlusPeakLimitAndSeconds() {
        let line = ShareDirectDiagnostics.line(started().finished(outcome()), now: t0)
        XCTAssertEqual(line, "2027-01-15T08:00:00Z build=116 pieces=3 deferred=1 bytes=2048 sent=2 queued=1 refused=0 stopped=-"
            + " footprint_mb_before=18.4 footprint_mb_after=22.0 footprint_mb_peak=61.3 limit_mb=120.0 seconds=12.3")
        let stopped = ShareDirectDiagnostics.line(started().finished(outcome(stopped: "lock_timeout")), now: t0)
        XCTAssertTrue(stopped.contains(" stopped=lock_timeout "), stopped)
    }

    func testStartedWithoutFinishIsInProgressInsideTheLeaseAndDidNotFinishAfterIt() {
        let record = started()
        let during = ShareDirectDiagnostics.line(record, now: t0.addingTimeInterval(ShareHandoff.sendingLease - 1))
        XCTAssertEqual(during, "2027-01-15T08:00:00Z build=116 pieces=3 deferred=1 bytes=2048 footprint_mb_before=18.4 limit_mb=120.0 in-progress")
        let after = ShareDirectDiagnostics.line(record, now: t0.addingTimeInterval(ShareHandoff.sendingLease))
        XCTAssertEqual(after, "2027-01-15T08:00:00Z build=116 pieces=3 deferred=1 bytes=2048 footprint_mb_before=18.4 limit_mb=120.0 did-not-finish",
                       "the extension ended mid-send (memory limit) — visible without a Mac")
    }

    func testUnreadableNumbersRenderAsDash() {
        let record = ShareDirectDiagnostics.Record(startedAt: t0, build: nil, pieces: 1, deferred: 0, bytes: 0, footprintBefore: nil, limit: .infinity)
        let done = record.finished(ShareDirectDiagnostics.Outcome(sent: 1, queued: 0, refused: 0, stopped: nil, footprintAfter: -1,
                                                                 footprintPeak: .nan, seconds: 0.04))
        XCTAssertEqual(ShareDirectDiagnostics.line(done, now: t0), "2027-01-15T08:00:00Z build=? pieces=1 deferred=0 bytes=0 sent=1 queued=0 refused=0"
            + " stopped=- footprint_mb_before=- footprint_mb_after=- footprint_mb_peak=- limit_mb=- seconds=0.0")
        store().begin(done)
        XCTAssertEqual(store().records(), [done], "non-finite values never reach the encoder")
    }

    func testSectionHasATitleAndSaysNoneWhenNothingWasRecorded() {
        XCTAssertEqual(store().lines(now: t0), ["share direct-send:", "(none)"])
        let record = started()
        store().begin(record)
        store().finish(record, outcome())
        XCTAssertEqual(store().lines(now: t0), ["share direct-send:", ShareDirectDiagnostics.line(record.finished(outcome()), now: t0)])
    }

    // MARK: - 실패는 조용히

    func testCorruptOrUnknownVersionFileReadsAsEmptyAndTheNextWriteReplacesIt() throws {
        try Data("not json".utf8).write(to: store().file)
        XCTAssertEqual(store().records(), [])
        try Data(#"{"version":99,"records":[]}"#.utf8).write(to: store().file)
        XCTAssertEqual(store().records(), [])
        let record = started()
        store().begin(record)
        XCTAssertEqual(store().records(), [record])
    }

    func testAMissingContainerNeverThrowsAndRecordsNothing() {
        let gone = ShareDirectDiagnosticsStore(container: temp.appendingPathComponent("no-such-container", isDirectory: true))
        let record = started()
        gone.begin(record)
        gone.finish(record, outcome())
        XCTAssertEqual(gone.records(), [])
        XCTAssertEqual(gone.lines(now: t0), ["share direct-send:", "(none)"])
    }

    // MARK: - 식별자 없음

    /// 계획·보고서에서 만든 기록은 조각의 **개수**만 싣는다 — 글·파일 이름·방·맡김 ID·정지 사유 문구가 파일에도 줄에도 없다.
    func testARecordBuiltFromThePlanAndReportCarriesCountsOnly() throws {
        let item = ShareHandoff.Item(id: "SECRET-id", createdAt: t0, scope: "SECRET-scope", room: "SECRET-room", text: "SECRET-text",
                                     files: ["0-SECRET-a.jpg", "1-SECRET-b.jpg", "2-SECRET-c.mov"])
        let sizes = ["0-SECRET-a.jpg": 1000, "1-SECRET-b.jpg": 24, "2-SECRET-c.mov": ShareDirectSend.maxDirectFileBytes + 1]
        let plan = ShareDirectSend.plan(item) { sizes[$0] }
        XCTAssertEqual(plan.directFileBytes { sizes[$0] }, 1024, "text counts as 0 bytes; deferred files are not counted")
        XCTAssertEqual(ShareDirectSend.Plan(direct: [.text, .file("x")]).directFileBytes { _ in nil }, 0, "an unreadable size counts as 0")

        var report = ShareDirectSend.Report()
        report.sent = [.text, .file("0-SECRET-a.jpg")]
        report.refused = [ShareDirectSend.Refusal(piece: .file("1-SECRET-b.jpg"), status: 413, code: "SECRET-code")]
        report.stopped = "halted: SECRET-reason owner-iphone-a1b2c3"
        let record = ShareDirectDiagnostics.Record(startedAt: t0, build: "116 SECRET", plan: plan, bytes: plan.directFileBytes { sizes[$0] },
                                                   footprintBefore: 18.4, limit: 120)
        store().begin(record)
        store().finish(record, ShareDirectDiagnostics.Outcome(report: report, footprintAfter: 22, footprintPeak: 61.3, seconds: 3))

        let raw = String(decoding: try Data(contentsOf: store().file), as: UTF8.self)
        let text = store().lines(now: t0).joined(separator: "\n")
        for leaked in ["SECRET", "owner-iphone", "jpg", "mov"] {
            XCTAssertFalse(raw.contains(leaked), "\(leaked) in the file: \(raw)")
            XCTAssertFalse(text.contains(leaked), "\(leaked) in the copied text: \(text)")
        }
        XCTAssertTrue(text.contains("build=116 pieces=3 deferred=1 bytes=1024 sent=2 queued=0 refused=1 stopped=halted "), text)
    }

    /// 디스크 형식의 필드는 이 목록이 전부다 — 새 필드를 더하면 여기서 걸린다(이름·ID 를 실을 자리를 몰래 만들 수 없다).
    func testTheDiskFormatHasExactlyTheCountAndMeasurementFields() throws {
        let record = started()
        store().begin(record)
        store().finish(record, outcome(stopped: "network"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store().file)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "records"])
        let first = try XCTUnwrap((json["records"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(first.keys), ["startedAt", "build", "pieces", "deferred", "bytes", "footprintBefore", "limit", "outcome"])
        let result = try XCTUnwrap(first["outcome"] as? [String: Any])
        XCTAssertEqual(Set(result.keys), ["sent", "queued", "refused", "stopped", "footprintAfter", "footprintPeak", "seconds"])
        let strings = first.values.compactMap { $0 as? String } + result.values.compactMap { $0 as? String }
        XCTAssertEqual(Set(strings), ["116", "network"], "the only strings are the build number and the stop token")
    }

    func testBuildAndStopTokensAreClosed() {
        XCTAssertEqual(ShareDirectDiagnostics.buildToken("116"), "116")
        XCTAssertEqual(ShareDirectDiagnostics.buildToken("1.2.3-beta owner"), "1.2.3")
        XCTAssertEqual(ShareDirectDiagnostics.buildToken("12345678901234567890"), "123456789012")
        XCTAssertEqual(ShareDirectDiagnostics.buildToken("가족"), "?")
        XCTAssertEqual(ShareDirectDiagnostics.buildToken(nil), "?")

        XCTAssertNil(ShareDirectDiagnostics.stopToken(nil))
        for token in ["not_joined", "registration_pending", "cas_retry_exhausted", "lock_timeout", "unauthorized", "network", "unreadable", "reconciled"] {
            XCTAssertEqual(ShareDirectDiagnostics.stopToken(token), token)
        }
        XCTAssertEqual(ShareDirectDiagnostics.stopToken("halted: 가족방 owner-iphone-a1b2c3 removed"), "halted", "the reason text is dropped")
        XCTAssertEqual(ShareDirectDiagnostics.stopToken("error: URLError"), "error", "the type name is dropped too")
        XCTAssertEqual(ShareDirectDiagnostics.stopToken("가족방"), "other")
        XCTAssertEqual(ShareDirectDiagnostics.stopToken("Family Room 42"), "amilyoom", "only lowercase letters and underscores survive")
        XCTAssertEqual(ShareDirectDiagnostics.stopToken(String(repeating: "a", count: 40))?.count, 24)
    }

    /// 파일을 누가 고쳐 써도(확장만 쓰지만) 복사되는 글에는 걸러진 토큰만 나간다.
    func testATamperedFileIsFilteredAgainWhenRendered() throws {
        let tampered = #"{"version":1,"records":[{"startedAt":1800000000000,"build":"116 SECRET-room","pieces":1,"deferred":0,"bytes":0,"#
            + #""outcome":{"sent":0,"queued":0,"refused":0,"stopped":"halted: SECRET-reason","seconds":1}}]}"#
        try Data(tampered.utf8).write(to: store().file)
        let text = store().lines(now: t0).joined(separator: "\n")
        XCTAssertFalse(text.contains("SECRET"), text)
        XCTAssertTrue(text.contains("build=116 "), text)
        XCTAssertTrue(text.contains(" stopped=halted "), text)
    }
}
