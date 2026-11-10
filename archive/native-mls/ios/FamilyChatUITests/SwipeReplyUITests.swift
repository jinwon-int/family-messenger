// 밀어서 답장 실제 터치 재현(오너 2026-11-10 「가장 최신 말풍선은 되는데 두 번째 이상은 잘 안 됨」).
// 재현 화면(`SwipeReplyHarness`, 실행 인자 `-swipeReplyHarness`)의 말풍선을 하나씩 왼쪽으로 밀고, 어느 행에 답장이 열렸는지와
// 팬 판정 기록을 `[swipe]` 줄로 남긴다 — 모든 행을 다 민 뒤에 판정해 한 번의 실행으로 행별 결과를 다 본다.
import XCTest

final class SwipeReplyUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(rows: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-swipeReplyHarness", "-swipeReplyRows", String(rows)]
        app.launch()
        XCTAssertTrue(app.staticTexts["harness-replied"].waitForExistence(timeout: 10))
        return app
    }

    private func bubble(_ app: XCUIApplication, _ n: Int) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "메시지 \(n) ")).firstMatch
    }

    /// 행 `n` 의 말풍선 글자 위에서 왼쪽으로 140pt 민다. 답장이 그 행으로 열렸으면 true.
    @discardableResult
    private func swipe(_ app: XCUIApplication, _ n: Int, label: String, clearFirst: Bool = true) -> Bool {
        if clearFirst { app.buttons["harness-clear"].tap() }
        let target = bubble(app, n)
        guard target.waitForExistence(timeout: 3), target.isHittable else {
            print("[swipe] \(label) row=\(n) NOT-HITTABLE frame=\(target.frame)")
            return false
        }
        let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = start.withOffset(CGVector(dx: -140, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0.05)
        let replied = app.staticTexts["harness-replied"].label
        app.buttons["harness-dump"].tap()
        let trace = app.staticTexts["harness-trace"].label.replacingOccurrences(of: "\n", with: " | ")
        let ok = replied == "replied:\(n)"
        print("[swipe] \(label) row=\(n) \(ok ? "OK" : "FAIL") \(replied) frame=\(target.frame) trace: \(trace)")
        return ok
    }

    /// 한 화면에 다 들어가는 8행: 최신(8)부터 위로 한 행씩.
    func testEveryVisibleRowReplies() {
        let app = launch(rows: 8)
        var failed: [Int] = []
        for n in stride(from: 8, through: 2, by: -1) where !swipe(app, n, label: "fit") { failed.append(n) }
        // 같은 행을 두 번 — 첫 끌기 뒤 상태가 남아 다음 끌기를 막는지.
        for n in [8, 7, 8, 6] where !swipe(app, n, label: "repeat") { failed.append(n) }
        XCTAssertEqual(failed, [], "swipe-to-reply failed on rows \(failed)")
    }

    /// 스크롤이 생기는 40행: 바닥에서 보이는 행들, 그다음 위로 스크롤한 뒤 가운데 행.
    func testRowsAfterScrolling() {
        let app = launch(rows: 40)
        var failed: [String] = []
        for n in [40, 39, 38, 36] where !swipe(app, n, label: "bottom") { failed.append("bottom-\(n)") }
        app.scrollViews.firstMatch.swipeDown()
        sleep(2)
        let visible = (1...40).reversed().first { bubble(app, $0).exists && bubble(app, $0).isHittable && $0 < 30 }
        if let n = visible {
            if !swipe(app, n, label: "scrolled") { failed.append("scrolled-\(n)") }
            if !swipe(app, n - 1, label: "scrolled") { failed.append("scrolled-\(n - 1)") }
        } else {
            print("[swipe] scrolled: no hittable row below 30")
        }
        // 스크롤 직후(감속 중) 바로 민다.
        app.scrollViews.firstMatch.swipeUp()
        if let n = (1...40).reversed().first(where: { bubble(app, $0).exists && bubble(app, $0).isHittable }) {
            if !swipe(app, n, label: "decelerating") { failed.append("decelerating-\(n)") }
        }
        XCTAssertEqual(failed, [], "swipe-to-reply failed: \(failed)")
    }

    /// 가운데쯤 보이는 행 번호(바닥·꼭대기 가장자리 제외).
    private func midRow(_ app: XCUIApplication) -> Int? {
        let window = app.windows.firstMatch.frame
        return (1...40).reversed().first { n in
            let b = bubble(app, n)
            guard b.exists, b.isHittable else { return false }
            return b.frame.midY > window.height * 0.45 && b.frame.midY < window.height * 0.75
        }
    }

    /// 감속 가설(1차 실측: 스크롤 2초 뒤 민 29행만 실패, 판정 기록 비어 있음)을 세 조건으로 나눠 본다.
    func testSwipeAfterFlingVersusSettled() {
        let app = launch(rows: 40)
        var failed: [String] = []
        let scroll = app.scrollViews.firstMatch
        // A. 아래로 휙(관성) → 곧바로 고정 좌표에서 민다(요소 조회는 수 초가 걸려 감속이 끝나 버린다).
        //    판정: recv(행 인식기에 터치 도착) 있음 + 답장 = OK, recv 있음 + 답장 없음 = GATED, recv 없음 = MISS(말풍선 사이 빈 곳).
        var gated = 0
        for round in 1...6 {
            app.buttons["harness-clear"].tap()
            scroll.swipeDown(velocity: .fast)
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45 + 0.04 * Double(round % 3)))
            start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: -140, dy: 0)),
                        withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0.05)
            let replied = app.staticTexts["harness-replied"].label
            app.buttons["harness-dump"].tap()
            let trace = app.staticTexts["harness-trace"].label.replacingOccurrences(of: "\n", with: " | ")
            let hitRow = trace.components(separatedBy: " | ").contains { $0.hasPrefix("recv ") }   // 탐침 줄은 "probe recv"
            let verdict = replied != "replied:none" ? "OK" : (hitRow ? "GATED" : "MISS")
            if verdict == "GATED" { gated += 1; failed.append("fling-now-\(round)") }
            print("[swipe] fling-now-\(round) \(verdict) \(replied) trace: \(trace)")
        }
        print("[swipe] fling-now gated=\(gated)/6")
        // B. 아래로 휙 → 5초 기다린 뒤 민다.
        for round in 1...2 {
            scroll.swipeDown(velocity: .fast)
            sleep(5)
            if let n = midRow(app) {
                if !swipe(app, n, label: "fling-wait5-\(round)") { failed.append("fling-wait5-\(round)-\(n)") }
            }
        }
        // C. 관성 없이 천천히 끌어 내리고(끝에서 멈춘 채 뗌) 바로 민다.
        for round in 1...2 {
            app.buttons["harness-clear"].tap()
            let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let to = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)
            if let n = midRow(app) {
                if !swipe(app, n, label: "slow-now-\(round)", clearFirst: false) { failed.append("slow-now-\(round)-\(n)") }
            }
        }
        print("[swipe] summary fling-vs-settled failed=\(failed)")
        XCTAssertEqual(failed, [], "swipe-to-reply failed: \(failed)")
    }
}
