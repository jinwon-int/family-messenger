// 밀어서 답장 실제 터치 회귀(#745, 오너 2026-11-10 「가장 최신 말풍선은 되는데 두 번째 이상은 잘 안 됨」).
// 재현 화면(`SwipeReplyHarness`, DEBUG 실행 인자 `-swipeReplyHarness`)에서 실제 `MessageRow`·`SwipeToReply` 를 민다.
// 행마다 `[swipe]` 줄(결과 · 말풍선 위치 · 팬 판정 기록)을 남기고, 모든 행을 다 민 뒤에 판정한다.
//
// 조사 기록(#746): 정지·스크롤 뒤·관성 직후·에이전트 카드(최신/이전) 모두 수평 밀기는 위치와 상관없이 성공 — 행 위치에 따른 코드
// 분기는 없었다. 차이는 엄지 궤적(위쪽 말풍선일수록 비스듬함)과 밀리는 동안 타임라인이 같이 세로로 움직이던 것 → 아래 대각선·잠금 회귀.
import XCTest

final class SwipeReplyUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-swipeReplyHarness"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["harness-replied"].waitForExistence(timeout: 10))
        return app
    }

    private func text(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// `prefix` 로 시작하는 글자 위에서 (dx, dy) 만큼 민다. 반환: 열린 답장(`replied:<seq>` / `replied:none`)과 밀기 전후 글자의 세로 이동.
    private func swipe(_ app: XCUIApplication, _ prefix: String, dx: CGFloat = -140, dy: CGFloat = 0,
                       at x: CGFloat = 0.6, label: String) -> (replied: String, moved: CGFloat)? {
        app.buttons["harness-clear"].tap()
        let el = text(app, prefix)
        guard el.waitForExistence(timeout: 3), el.isHittable, el.frame.minX > 0 else {
            print("[swipe] \(label) '\(prefix)' NOT-HITTABLE frame=\(el.frame)")
            return nil
        }
        // 밀기 전 frame 을 값으로 잡아 둔다 — `el.frame` 은 읽을 때마다 다시 조회돼, 밀기 뒤에 찍으면 옆으로 스크롤된 위치가 나온다
        // (#747: 표 칸의 밀기 뒤 x=-5.3 을 처음 위치로 읽어 「처음부터 가운데로 스크롤됨」으로 오진).
        let startFrame = el.frame
        let start = el.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)),
                    withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0.05)
        let replied = app.staticTexts["harness-replied"].label
        let endFrame = text(app, prefix).frame
        let moved = endFrame.minY - startFrame.minY
        app.buttons["harness-dump"].tap()
        let trace = app.staticTexts["harness-trace"].label.replacingOccurrences(of: "\n", with: " | ")
        print("[swipe] \(label) '\(prefix)' \(replied) moved=\(Int(moved)) start=\(startFrame) end=\(endFrame) trace: \(trace)")
        return (replied, moved)
    }

    /// 한 화면에 다 들어가는 8행: 최신(8)부터 위로 한 행씩 수평으로.
    func testEveryVisibleRowReplies() {
        let app = launch(["-swipeReplyRows", "8"])
        var failed: [String] = []
        for n in stride(from: 8, through: 2, by: -1) {
            if let r = swipe(app, "메시지 \(n) ", at: 0.85, label: "fit-\(n)"), r.replied != "replied:\(n)" { failed.append("fit-\(n)") }
        }
        XCTAssertEqual(failed, [], "swipe-to-reply failed on \(failed)")
    }

    /// #745: 위쪽 말풍선을 엄지로 미는 비스듬한 궤적(왼쪽 위·왼쪽 아래 약 34°) — 종전 1.5배 판정은 시작조차 하지 않았다.
    /// 밀리는 동안 타임라인이 세로로 움직이지 않아야 한다(말풍선이 손가락 아래에 남는다).
    func testDiagonalThumbSwipeRepliesOnLatestAndOlderRows() {
        // 40행(스크롤 가능)이라야 잠금이 보인다 — 한 화면에 다 들어가면 타임라인이 고무줄처럼 제자리로 돌아와 이동이 0 으로 잰다.
        let app = launch(["-swipeReplyRows", "40"])
        var failed: [String] = []
        for n in [40, 39, 37, 36, 34] {
            for (dy, tag) in [(CGFloat(-95), "up"), (CGFloat(95), "down")] {
                let label = "diag-\(tag)-\(n)"
                guard let r = swipe(app, "메시지 \(n) ", dx: -140, dy: dy, at: 0.85, label: label) else { continue }
                if r.replied != "replied:\(n)" { failed.append(label) }
                if abs(r.moved) > 2 { failed.append("\(label)-timeline-moved-\(Int(r.moved))") }
            }
        }
        XCTAssertEqual(failed, [], "diagonal swipe-to-reply failed: \(failed)")
    }

    /// 회귀(#732): 말풍선 위에서 시작한 세로 끌기는 여전히 타임라인을 스크롤하고 답장을 열지 않는다.
    func testVerticalDragOnBubbleStillScrolls() {
        let app = launch(["-swipeReplyRows", "40"])
        guard let r = swipe(app, "메시지 38 ", dx: 0, dy: 260, at: 0.5, label: "vertical") else {
            XCTFail("row 38 not hittable"); return
        }
        XCTAssertEqual(r.replied, "replied:none", "a vertical drag must not reply")
        XCTAssertGreaterThan(r.moved, 100, "a vertical drag on a bubble must scroll the timeline")
    }

    /// 회귀 지킴(#747): 가로로 넘치는 표는 왼쪽 끝에서 시작한다 — 타임라인의 바닥 앵커(`.bottom`, x 0.5)가 안쪽 가로 스크롤에
    /// 번져 첫 열이 카드 밖으로 잘리면 안 된다. #747 의 의심은 재현되지 않았다(수정 없는 main 에서도 첫 열 칸 x=30 = 카드 글자 x=30;
    /// 「x=-5.3」은 밀기 뒤 위치였다). 앵커 구성이 바뀌어도 이 성질이 남는지 지킨다. 첫 열 칸의 왼쪽 끝 ≥ 같은 카드 글자의 왼쪽 끝.
    func testWideTableStartsAtLeadingEdge() {
        let app = launch(["-swipeReplyRows", "6", "-swipeReplyAgent"])
        let cell = text(app, "표칸 6")
        let para = text(app, "첫 문단 6")
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "table cell missing")
        XCTAssertTrue(para.waitForExistence(timeout: 5), "card text missing")
        print("[swipe] table-leading cell=\(cell.frame) text=\(para.frame)")
        XCTAssertGreaterThanOrEqual(cell.frame.minX, para.frame.minX - 1,
                                    "wide table starts scrolled: first column minX \(cell.frame.minX) < card text minX \(para.frame.minX)")
    }

    /// 표·목록이 든 에이전트 카드(오너가 주로 답하는 보고서): 최신 카드와 그 위 카드의 글자에서는 답장, 표 칸 위에서는 표 몫(답장 없음).
    func testAgentCardsLatestAndOlder() {
        let app = launch(["-swipeReplyRows", "6", "-swipeReplyAgent"])
        var failed: [String] = []
        func expect(_ n: Int, _ prefix: String, _ label: String, dy: CGFloat = 0) {
            if let r = swipe(app, prefix, dy: dy, label: label), r.replied != "replied:\(n)" { failed.append(label) }
        }
        expect(6, "마지막 문단 6", "latest-last")
        expect(6, "목록 하나 6", "latest-list")
        expect(6, "첫 문단 6", "latest-first")
        expect(6, "첫 문단 6", "latest-first-diag", dy: -90)
        if let c = swipe(app, "표칸 6", at: 0.5, label: "latest-table-control"), c.replied != "replied:none" {
            failed.append("latest-table-control")
        }
        let scroll = app.scrollViews.firstMatch
        for n in [5, 4] {
            for _ in 0..<4 {
                let el = text(app, "마지막 문단 \(n)")
                if el.exists && el.isHittable && el.frame.midY > 300 { break }
                let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.35))
                from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 250)), withVelocity: .slow, thenHoldForDuration: 0.4)
            }
            expect(n, "마지막 문단 \(n)", "older\(n)-last")
            expect(n, "목록 하나 \(n)", "older\(n)-list")
            expect(n, "마지막 문단 \(n)", "older\(n)-last-diag", dy: -90)
        }
        print("[swipe] summary agent failed=\(failed)")
        XCTAssertEqual(failed, [], "agent swipe-to-reply failed: \(failed)")
    }
}
