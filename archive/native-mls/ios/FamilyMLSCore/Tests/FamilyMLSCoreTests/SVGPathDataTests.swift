import XCTest
@testable import FamilyMLSCore

/// #414 오프닝 일러스트: 시안 path 문자열이 앱에서 같은 좌표로 해석되는가.
final class SVGPathDataTests: XCTestCase {
    typealias P = SVGPathData.Point

    func testAbsoluteCurvesAndClose() {
        let cmds = SVGPathData.parse("M14 0 C10 -20 12 -46 22 -62 L40 0 Z")
        XCTAssertEqual(cmds, [.move(P(14, 0)), .cubic(P(10, -20), P(12, -46), P(22, -62)), .line(P(40, 0)), .close])
    }

    func testRelativeLinesAndQuadsAreFromTheCommandStart() {
        XCTAssertEqual(SVGPathData.parse("M154 652 l52 -11 M154 641 l52 11"),
                       [.move(P(154, 652)), .line(P(206, 641)), .move(P(154, 641)), .line(P(206, 652))])
        XCTAssertEqual(SVGPathData.parse("M60 -52 q-3 -6 1 -11"), [.move(P(60, -52)), .quad(P(57, -58), P(61, -63))])
        XCTAssertEqual(SVGPathData.parse("M0 0 c1 1 2 2 3 3 c1 1 2 2 3 3"),
                       [.move(P(0, 0)), .cubic(P(1, 1), P(2, 2), P(3, 3)), .cubic(P(4, 4), P(5, 5), P(6, 6))])
    }

    /// 2차-B 불지기 아이콘의 어깨 `s`: 앞 3차의 둘째 제어점을 현재점에 반사한 점이 첫 제어점. 앞이 3차가 아니면 현재점.
    func testSmoothCubicReflectsThePreviousControlPoint() {
        XCTAssertEqual(SVGPathData.parse("M0 0c1 1 2 2 3 3s2 2 3 3"),
                       [.move(P(0, 0)), .cubic(P(1, 1), P(2, 2), P(3, 3)), .cubic(P(4, 4), P(5, 5), P(6, 6))])
        XCTAssertEqual(SVGPathData.parse("M0 0C1 1 2 2 3 3S5 5 6 6"),
                       [.move(P(0, 0)), .cubic(P(1, 1), P(2, 2), P(3, 3)), .cubic(P(4, 4), P(5, 5), P(6, 6))])
        XCTAssertEqual(SVGPathData.parse("M0 0l1 1s2 2 3 3"), [.move(P(0, 0)), .line(P(1, 1)), .cubic(P(1, 1), P(3, 3), P(4, 4))])
        // 연달아 s: 둘째 s 는 첫 s 의 둘째 제어점을 반사한다.
        XCTAssertEqual(SVGPathData.parse("M0 0c1 1 2 2 3 3s2 2 3 3s2 2 3 3")?.last, .cubic(P(7, 7), P(8, 8), P(9, 9)))
        XCTAssertNotNil(SVGPathData.parse("M4 20.5c0-3.7 2.7-6.2 6-6.2s6 2.5 6 6.2"))
    }

    func testImplicitRepeatsCommasAndDecimals() {
        XCTAssertEqual(SVGPathData.parse("M1,2 3,4 L5 6 7 8"), [.move(P(1, 2)), .line(P(3, 4)), .line(P(5, 6)), .line(P(7, 8))])
        XCTAssertEqual(SVGPathData.parse("M52.5-83.5 h2 v-1.5"), [.move(P(52.5, -83.5)), .line(P(54.5, -83.5)), .line(P(54.5, -85))])
    }

    func testMalformedPathIsRejectedNotHalfDrawn() {
        XCTAssertNil(SVGPathData.parse("M0 0 T1 1"), "T 는 쓰지 않는다")
        XCTAssertNil(SVGPathData.parse("M0 0 A1 1 0 0 1 2"), "호는 매개변수 7개")
        XCTAssertNil(SVGPathData.parse("M0 0 S1 1 2"), "S 는 매개변수 4개")
        XCTAssertNil(SVGPathData.parse("M0 0 C1 2"))
        XCTAssertNil(SVGPathData.parse("10 10"))
        XCTAssertEqual(SVGPathData.parse(""), [])
    }
}
