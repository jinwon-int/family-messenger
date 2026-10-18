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

    func testImplicitRepeatsCommasAndDecimals() {
        XCTAssertEqual(SVGPathData.parse("M1,2 3,4 L5 6 7 8"), [.move(P(1, 2)), .line(P(3, 4)), .line(P(5, 6)), .line(P(7, 8))])
        XCTAssertEqual(SVGPathData.parse("M52.5-83.5 h2 v-1.5"), [.move(P(52.5, -83.5)), .line(P(54.5, -83.5)), .line(P(54.5, -85))])
    }

    func testMalformedPathIsRejectedNotHalfDrawn() {
        XCTAssertNil(SVGPathData.parse("M0 0 A1 1 0 0 1 2 2"))
        XCTAssertNil(SVGPathData.parse("M0 0 C1 2"))
        XCTAssertNil(SVGPathData.parse("10 10"))
        XCTAssertEqual(SVGPathData.parse(""), [])
    }
}
