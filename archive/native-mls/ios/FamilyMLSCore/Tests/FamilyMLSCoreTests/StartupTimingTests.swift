// 시작 구간 계측(#836, `StartupTiming`) — 구간 합 = 총합 · 한 번만 · 이름 깎기 · 시계 역행 · 첫 동기화 줄.
import XCTest
@testable import FamilyMLSCore

final class StartupTimingTests: XCTestCase {
    /// 시작 100 s(단조 시계) 기준.
    private func timing() -> StartupTiming { StartupTiming(origin: 100) }

    func testStoredFirstLineNamesEachStageAndTheStagesAddUpToTheTotal() throws {
        var t = timing()
        t.mark("launch", at: 100.300)
        t.mark("identity", at: 100.395)
        t.mark("rooms", at: 100.412)
        let line = t.finish("stored", at: 100.412, awaitingSync: true)
        XCTAssertEqual(line, "startup: first screen 412 ms (stored) — launch 300 · identity 95 · rooms 17")
        let summary = try XCTUnwrap(t.firstScreen)
        XCTAssertEqual(summary.stages.map(\.ms).reduce(0, +), summary.total)
        XCTAssertTrue(t.finished)
        XCTAssertTrue(t.awaitsFirstSync)
    }

    func testNetworkLineCarriesTheRelayStagesAndARestStageForWhatIsLeft() {
        var t = timing()
        t.mark("launch", at: 100.3)
        t.mark("identity", at: 100.4)
        t.mark("rooms", at: 100.42)
        t.mark("listing", at: 100.83)
        t.mark("sync", at: 101.6)
        let line = t.finish("network", at: 101.65)
        XCTAssertEqual(line, "startup: first screen 1650 ms (network) — launch 300 · identity 100 · rooms 20 · listing 410 · sync 770 · rest 50")
        XCTAssertFalse(t.awaitsFirstSync, "drawn after the relay answered — no first-sync line to wait for")
        XCTAssertNil(t.finishFirstSync("ready", at: 102))
        XCTAssertEqual(t.lines, [line!])
    }

    func testFinishIsOnceAndLaterMarksAreIgnored() {
        var t = timing()
        t.mark("launch", at: 100.1)
        XCTAssertNotNil(t.finish("login", at: 100.2))
        t.mark("identity", at: 100.3)
        XCTAssertNil(t.finish("ready", at: 100.4), "a later screen does not record again")
        let expected = StartupTiming.Summary(screen: "login", total: 200, stages: [
            StartupTiming.Stage(name: "launch", ms: 100), StartupTiming.Stage(name: "rest", ms: 100),
        ])
        XCTAssertEqual(t.firstScreen, expected)
    }

    func testDuplicateMarksKeepTheFirstAndTheStageCountIsCapped() {
        var t = timing()
        t.mark("launch", at: 100.1)
        t.mark("launch", at: 100.5)
        for i in 0..<40 { t.mark("s\(i)", at: 100.6) }
        _ = t.finish("ready", at: 100.6)
        let stages = t.firstScreen?.stages ?? []
        XCTAssertEqual(stages.first, StartupTiming.Stage(name: "launch", ms: 100), "the first launch mark wins")
        XCTAssertEqual(stages.filter { $0.name != StartupTiming.restStage }.count, StartupTiming.maxStages)
    }

    func testClockGoingBackwardsNeverGivesANegativeStage() {
        var t = timing()
        t.mark("launch", at: 100.5)
        t.mark("identity", at: 100.2)   // 앞 표시보다 이르다
        let line = t.finish("stored", at: 99)   // 시작보다도 이르다
        XCTAssertEqual(line, "startup: first screen 500 ms (stored) — launch 500 · identity 0")
        XCTAssertTrue((t.firstScreen?.stages ?? []).allSatisfy { $0.ms >= 0 })
    }

    func testNoStagesGivesTheBareLineAndNamesAreCleaned() {
        var bare = timing()
        XCTAssertEqual(bare.finish("fatal", at: 100), "startup: first screen 0 ms (fatal)")
        var t = timing()
        t.mark("방 room/family 1", at: 100.01)
        t.mark("", at: 100.02)
        t.mark(String(repeating: "a", count: 40), at: 100.03)
        _ = t.finish("stored (x)", at: 100.03)
        XCTAssertEqual(t.firstScreen?.screen, "storedx")
        XCTAssertEqual(t.firstScreen?.stages.map(\.name), ["roomfamily1", "stage", String(repeating: "a", count: 24)])
    }

    func testNonFiniteClockReadsAsZero() {
        var t = timing()
        t.mark("launch", at: .nan)
        XCTAssertEqual(t.finish("login", at: .infinity), "startup: first screen 0 ms (login) — launch 0")
    }

    func testFirstSyncIsRecordedOnceOnlyAfterAScreenDrawnAheadOfIt() {
        var early = timing()
        XCTAssertNil(early.finishFirstSync("ready", at: 101), "no first screen yet")

        var t = timing()
        t.mark("launch", at: 100.3)
        _ = t.finish("stored", at: 100.4, awaitingSync: true)
        XCTAssertEqual(t.finishFirstSync("ready", at: 101.18), "startup: first sync 1180 ms (ready)")
        XCTAssertFalse(t.awaitsFirstSync)
        XCTAssertNil(t.finishFirstSync("offline", at: 102), "once")
        XCTAssertEqual(t.lines, ["startup: first screen 400 ms (stored) — launch 300 · rest 100", "startup: first sync 1180 ms (ready)"])

        var late = timing()
        _ = late.finish("timeout", at: 108, awaitingSync: true)
        XCTAssertEqual(late.finishFirstSync("enroll", at: 107), "startup: first sync 8000 ms (enroll)",
                       "never earlier than the first screen it follows")
    }
}
