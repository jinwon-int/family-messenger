import XCTest
@testable import FamilyMLSCore

/// 웹 한데 keyboard.js(#478) 휴대폰 세로 규칙과의 동등성 — iOS 하드웨어 키보드 단축키.
final class HardwareKeysTests: XCTestCase {
    private typealias K = HardwareKeys

    func testRoomActionsMatchWebSinglePane() {
        // 작성창에 커서가 있을 때.
        XCTAssertEqual(K.roomAction(.init(.pageUp), mode: .composer), .previousRoom)   // 작성 중이어도 방을 넘긴다(웹 'switch')
        XCTAssertEqual(K.roomAction(.init(.pageDown), mode: .composer), .nextRoom)
        XCTAssertEqual(K.roomAction(.init(.home), mode: .composer), .backToList)       // 웹 viewKeyAction Home
        XCTAssertEqual(K.roomAction(.init(.escape), mode: .composer), .readTimeline)   // 웹 'focus-timeline'
        XCTAssertEqual(K.roomAction(.init(.end), mode: .composer), .readTimeline)
        XCTAssertEqual(K.roomAction(.init(.enter), mode: .composer), .send)            // 웹 composerKeyAction 'send'
        XCTAssertEqual(K.roomAction(.init(.enter, .shift), mode: .composer), .newline) // 'newline'
        XCTAssertNil(K.roomAction(.init(.upArrow), mode: .composer))                   // 작성창 안 커서 이동
        XCTAssertNil(K.roomAction(.init(.downArrow), mode: .composer))
        XCTAssertNil(K.roomAction(.init(.letterC), mode: .composer))                   // 글자 입력

        // 대화 읽기(작성창 밖).
        XCTAssertEqual(K.roomAction(.init(.pageUp), mode: .reading), .previousRoom)
        XCTAssertEqual(K.roomAction(.init(.pageDown), mode: .reading), .nextRoom)
        XCTAssertEqual(K.roomAction(.init(.home), mode: .reading), .backToList)
        XCTAssertEqual(K.roomAction(.init(.upArrow), mode: .reading), .scrollUp)       // 웹 'scroll-up'
        XCTAssertEqual(K.roomAction(.init(.downArrow), mode: .reading), .scrollDown)
        XCTAssertEqual(K.roomAction(.init(.enter), mode: .reading), .focusComposer)    // 웹 viewKeyAction Enter
        XCTAssertEqual(K.roomAction(.init(.end), mode: .reading), .scrollToLatest)
        XCTAssertEqual(K.roomAction(.init(.escape), mode: .reading), .startSelecting)  // 웹 'enter-caret'
        XCTAssertNil(K.roomAction(.init(.letterC, .command), mode: .reading))          // 고른 말풍선이 없다

        // 선택 모드(웹 캐럿 모드).
        XCTAssertEqual(K.roomAction(.init(.upArrow), mode: .selecting), .selectUp)
        XCTAssertEqual(K.roomAction(.init(.downArrow), mode: .selecting), .selectDown)
        XCTAssertEqual(K.roomAction(.init(.enter), mode: .selecting), .openSelection)
        XCTAssertEqual(K.roomAction(.init(.letterC, .command), mode: .selecting), .copySelection)
        XCTAssertEqual(K.roomAction(.init(.escape), mode: .selecting), .readTimeline)  // 웹 'exit-caret'
        XCTAssertEqual(K.roomAction(.init(.end), mode: .selecting), .scrollToLatest)
        // 웹 캐럿 모드처럼 방을 넘기거나 목록으로 가지 않는다.
        XCTAssertNil(K.roomAction(.init(.pageUp), mode: .selecting))
        XCTAssertNil(K.roomAction(.init(.pageDown), mode: .selecting))
        XCTAssertNil(K.roomAction(.init(.home), mode: .selecting))
        XCTAssertNil(K.roomAction(.init(.letterC), mode: .selecting))
    }

    func testModifiedKeysAreLeftToEditing() {
        let modes: [K.RoomMode] = [.composer, .reading, .selecting]
        for modifiers: K.Modifiers in [.shift, .command, .option, .control, [.shift, .command]] {
            for key: K.Key in [.pageUp, .pageDown, .home, .end, .escape, .upArrow, .downArrow, .enter, .letterC] {
                for mode in modes {
                    let allowed = (mode == .composer && key == .enter && modifiers == .shift)
                        || (mode == .selecting && key == .letterC && modifiers == .command)
                    if allowed { continue }
                    XCTAssertNil(K.roomAction(.init(key, modifiers), mode: mode), "\(key) \(modifiers) \(mode)")
                }
                XCTAssertNil(K.listAction(.init(key, modifiers), count: 3, highlighted: 1, anchor: nil, orderEditing: false), "\(key) \(modifiers)")
            }
        }
        XCTAssertNil(K.roomAction(.init(.enter, .command), mode: .composer))   // ⌘↩ 는 SwiftUI 단축키가 보낸다(두 번 보내지 않게)
    }

    func testSelectTargetClampsAtEnds() {
        let rows: [Int64] = [10, 11, 15]
        XCTAssertEqual(K.selectTarget(rows: rows, cursor: nil, step: 0), 15)   // 시작 = 마지막 말풍선
        XCTAssertEqual(K.selectTarget(rows: rows, cursor: 99, step: 0), 15)    // 사라진 커서
        XCTAssertEqual(K.selectTarget(rows: rows, cursor: 15, step: -1), 11)
        XCTAssertEqual(K.selectTarget(rows: rows, cursor: 10, step: -1), 10)   // 맨 위 제자리
        XCTAssertEqual(K.selectTarget(rows: rows, cursor: 15, step: 1), 15)    // 맨 아래로 빠지지 않는다
        XCTAssertEqual(K.selectTarget(rows: rows, cursor: 11, step: 0), 11)    // 읽던 자리에서 시작
        XCTAssertNil(K.selectTarget(rows: [], cursor: nil, step: 0))
    }

    func testInsertedNewlineAndOutgoingText() {
        XCTAssertTrue(K.insertedNewline(old: "", new: "\n"))
        XCTAssertTrue(K.insertedNewline(old: "안녕", new: "안녕\n"))
        XCTAssertTrue(K.insertedNewline(old: "ab", new: "a\nb"))          // 가운데 커서
        XCTAssertFalse(K.insertedNewline(old: "ab", new: "abc"))
        XCTAssertFalse(K.insertedNewline(old: "ab", new: "ab\n\n"))
        XCTAssertFalse(K.insertedNewline(old: "안", new: "안녕"))          // 한글 조합 확정은 줄바꿈이 아니다
        XCTAssertEqual(K.outgoingText("안녕\n"), "안녕")
        XCTAssertEqual(K.outgoingText("첫 줄\n둘째 줄  \n"), "첫 줄\n둘째 줄")
        XCTAssertNil(K.outgoingText(" \n "))
        XCTAssertNil(K.outgoingText(""))
    }

    func testPageMoveMatchesWebListPageMove() {
        // 웹 keyboard.test: 출발점 없음 → PageDown 첫 행 · PageUp 마지막 행, 끝에서는 제자리, 빈 목록은 nil.
        XCTAssertEqual(K.pageMove(down: true, count: 3, current: nil), 0)
        XCTAssertEqual(K.pageMove(down: false, count: 3, current: nil), 2)
        XCTAssertEqual(K.pageMove(down: true, count: 3, current: 0), 1)
        XCTAssertEqual(K.pageMove(down: false, count: 3, current: 1), 0)
        XCTAssertEqual(K.pageMove(down: true, count: 3, current: 2), 2)
        XCTAssertEqual(K.pageMove(down: false, count: 3, current: 0), 0)
        XCTAssertEqual(K.pageMove(down: true, count: 3, current: 7), 0)    // 범위 밖 = 출발점 없음
        XCTAssertEqual(K.pageMove(down: false, count: 3, current: -1), 2)
        XCTAssertNil(K.pageMove(down: true, count: 0, current: nil))
    }

    func testListActions() {
        // 표시가 없으면 방금 나온 방(anchor)에서 출발한다.
        XCTAssertEqual(K.listAction(.init(.pageDown), count: 4, highlighted: nil, anchor: 1, orderEditing: false), .highlight(2))
        XCTAssertEqual(K.listAction(.init(.pageUp), count: 4, highlighted: nil, anchor: 1, orderEditing: false), .highlight(0))
        XCTAssertEqual(K.listAction(.init(.pageDown), count: 4, highlighted: nil, anchor: nil, orderEditing: false), .highlight(0))
        // 표시가 있으면 표시에서 출발한다(anchor 보다 먼저).
        XCTAssertEqual(K.listAction(.init(.pageDown), count: 4, highlighted: 3, anchor: 0, orderEditing: false), .highlight(3))
        // Enter 는 표시된 행만 연다 — 보이지 않는 출발점(anchor)은 열지 않는다.
        XCTAssertEqual(K.listAction(.init(.enter), count: 4, highlighted: 2, anchor: nil, orderEditing: false), .open(2))
        XCTAssertNil(K.listAction(.init(.enter), count: 4, highlighted: nil, anchor: 2, orderEditing: false))
        XCTAssertNil(K.listAction(.init(.enter), count: 2, highlighted: 5, anchor: nil, orderEditing: false))
        // 순서 모드·빈 목록에서는 아무것도 하지 않는다(웹 #480 A).
        XCTAssertNil(K.listAction(.init(.pageDown), count: 4, highlighted: nil, anchor: nil, orderEditing: true))
        XCTAssertNil(K.listAction(.init(.enter), count: 4, highlighted: 1, anchor: nil, orderEditing: true))
        XCTAssertNil(K.listAction(.init(.pageDown), count: 0, highlighted: nil, anchor: nil, orderEditing: false))
        // 목록 화면의 다른 키는 쓰지 않는다.
        for key: K.Key in [.home, .end, .escape, .upArrow, .downArrow] {
            XCTAssertNil(K.listAction(.init(key), count: 4, highlighted: 1, anchor: nil, orderEditing: false), "\(key)")
        }
    }

    func testScrollTargetStepsOneBubble() {
        let rows: [Int64] = [10, 11, 15, 20]
        // 커서 없음(방금 읽기 시작) = 마지막 말풍선 기준.
        XCTAssertEqual(K.scrollTarget(rows: rows, cursor: nil, up: true), .row(15))
        XCTAssertEqual(K.scrollTarget(rows: rows, cursor: nil, up: false), .latest)
        XCTAssertEqual(K.scrollTarget(rows: rows, cursor: 15, up: true), .row(11))
        XCTAssertEqual(K.scrollTarget(rows: rows, cursor: 11, up: false), .row(15))
        XCTAssertEqual(K.scrollTarget(rows: rows, cursor: 15, up: false), .row(20))
        XCTAssertEqual(K.scrollTarget(rows: rows, cursor: 20, up: false), .latest)
        XCTAssertEqual(K.scrollTarget(rows: rows, cursor: 10, up: true), .row(10))   // 맨 위 제자리
        XCTAssertEqual(K.scrollTarget(rows: rows, cursor: 99, up: true), .row(15))   // 사라진 커서 = 마지막에서 다시
        XCTAssertNil(K.scrollTarget(rows: [], cursor: nil, up: true))
        XCTAssertEqual(K.scrollTarget(rows: [], cursor: nil, up: false), .latest)
    }

    func testDeduperDropsOtherPathDeliveryOfOnePress() {
        var dedupe = KeyDeduper(window: 0.5)
        XCTAssertTrue(dedupe.accept("nextRoom", from: .shortcut, at: 100.000))
        XCTAssertFalse(dedupe.accept("nextRoom", from: .gameController, at: 100.300))  // 같은 누름이 다른 길로 늦게 도착(메인 스레드 막힘)
        XCTAssertTrue(dedupe.accept("nextRoom", from: .shortcut, at: 100.120))         // 같은 길의 빠른 두 번째 누름은 살린다
        XCTAssertTrue(dedupe.accept("previousRoom", from: .gameController, at: 100.130)) // 다른 동작은 막지 않는다
        XCTAssertTrue(dedupe.accept("nextRoom", from: .gameController, at: 100.700))  // 창 밖 = 새 누름
        XCTAssertTrue(dedupe.accept("nextRoom", from: .gameController, at: 100.750))  // GameController 만 오는 경우(작성창) 빠른 연타
        XCTAssertTrue(dedupe.accept("nextRoom", from: .shortcut, at: 50.0))           // 시계가 뒤로 가면(재부팅 등) 막지 않는다
    }

    func testSendGuardAfterEnterFocus() {
        XCTAssertFalse(K.suppressSend(sinceKeyFocus: nil))    // 손으로 작성창을 누른 경우
        XCTAssertTrue(K.suppressSend(sinceKeyFocus: 0.0))
        XCTAssertTrue(K.suppressSend(sinceKeyFocus: 0.55))    // 키 반복으로 들어온 줄바꿈
        XCTAssertFalse(K.suppressSend(sinceKeyFocus: 0.8))
        XCTAssertFalse(K.suppressSend(sinceKeyFocus: 5))
        XCTAssertFalse(K.suppressSend(sinceKeyFocus: -1))     // 시계 역행은 막지 않는다
    }
}
