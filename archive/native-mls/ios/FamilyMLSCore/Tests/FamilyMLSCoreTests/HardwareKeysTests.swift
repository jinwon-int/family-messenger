import XCTest
@testable import FamilyMLSCore

/// 웹 한데 keyboard.js(#478) 휴대폰 세로 규칙과의 동등성 — iOS 하드웨어 키보드 단축키.
final class HardwareKeysTests: XCTestCase {
    private typealias K = HardwareKeys

    func testRoomActionsMatchWebSinglePane() {
        // 작성창에 커서가 있을 때.
        XCTAssertEqual(K.roomAction(.init(.pageUp), composerFocused: true), .previousRoom)   // 작성 중이어도 방을 넘긴다(웹 'switch')
        XCTAssertEqual(K.roomAction(.init(.pageDown), composerFocused: true), .nextRoom)
        XCTAssertEqual(K.roomAction(.init(.home), composerFocused: true), .backToList)       // 웹 viewKeyAction Home
        XCTAssertEqual(K.roomAction(.init(.escape), composerFocused: true), .readTimeline)   // 웹 'focus-timeline'
        XCTAssertEqual(K.roomAction(.init(.end), composerFocused: true), .readTimeline)
        XCTAssertNil(K.roomAction(.init(.enter), composerFocused: true))                     // 전송은 ComposerKeys
        XCTAssertNil(K.roomAction(.init(.upArrow), composerFocused: true))                   // 작성창 안 커서 이동
        XCTAssertNil(K.roomAction(.init(.downArrow), composerFocused: true))

        // 대화 읽기(작성창 밖).
        XCTAssertEqual(K.roomAction(.init(.pageUp), composerFocused: false), .previousRoom)
        XCTAssertEqual(K.roomAction(.init(.pageDown), composerFocused: false), .nextRoom)
        XCTAssertEqual(K.roomAction(.init(.home), composerFocused: false), .backToList)
        XCTAssertEqual(K.roomAction(.init(.upArrow), composerFocused: false), .scrollUp)     // 웹 'scroll-up'
        XCTAssertEqual(K.roomAction(.init(.downArrow), composerFocused: false), .scrollDown)
        XCTAssertEqual(K.roomAction(.init(.enter), composerFocused: false), .focusComposer)  // 웹 viewKeyAction Enter
        XCTAssertEqual(K.roomAction(.init(.end), composerFocused: false), .scrollToLatest)
        XCTAssertNil(K.roomAction(.init(.escape), composerFocused: false))                   // 캐럿 모드는 옮기지 않는다
    }

    func testModifiedKeysAreLeftToEditing() {
        for modifiers: K.Modifiers in [.shift, .command, .option, .control, [.shift, .command]] {
            for key: K.Key in [.pageUp, .pageDown, .home, .end, .escape, .upArrow, .downArrow, .enter] {
                XCTAssertNil(K.roomAction(.init(key, modifiers), composerFocused: true), "\(key) \(modifiers)")
                XCTAssertNil(K.roomAction(.init(key, modifiers), composerFocused: false), "\(key) \(modifiers)")
                XCTAssertNil(K.listAction(.init(key, modifiers), count: 3, highlighted: 1, anchor: nil, orderEditing: false), "\(key) \(modifiers)")
            }
        }
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

    func testDeduperDropsSecondDeliveryOfOnePress() {
        var dedupe = KeyDeduper(window: 0.08)
        XCTAssertTrue(dedupe.accept("nextRoom", at: 100.000))
        XCTAssertFalse(dedupe.accept("nextRoom", at: 100.010))   // 같은 누름이 두 번째 길로 도착
        XCTAssertTrue(dedupe.accept("previousRoom", at: 100.012)) // 다른 동작은 막지 않는다
        XCTAssertTrue(dedupe.accept("nextRoom", at: 100.150))    // 일부러 다시 누름
        XCTAssertTrue(dedupe.accept("nextRoom", at: 50.0))       // 시계가 뒤로 가면(재부팅 등) 막지 않는다
    }
}
