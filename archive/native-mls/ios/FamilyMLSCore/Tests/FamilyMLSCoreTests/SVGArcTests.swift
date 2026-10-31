import XCTest
@testable import FamilyMLSCore

/// 디자인 2차-B: 한데 UI 아이콘 정본(docs/design/icons/ui/*.svg)은 호(`a`)를 쓴다 — 파서가 호를 3차 베지어로 바꿔 끝까지 읽는가.
final class SVGArcTests: XCTestCase {
    typealias P = SVGPathData.Point

    private func points(_ commands: [SVGPathData.Command]) -> [P] {
        var out: [P] = []
        for command in commands {
            switch command {
            case .move(let a), .line(let a): out.append(a)
            case .cubic(let c1, let c2, let e): out += [c1, c2, e]
            case .quad(let q, let e): out += [q, e]
            case .close: break
            }
        }
        return out
    }

    private func cubics(_ commands: [SVGPathData.Command]) -> [(P, P, P)] {
        commands.compactMap { if case .cubic(let a, let b, let c) = $0 { return (a, b, c) } else { return nil } }
    }

    private func assertClose(_ a: P, _ b: P, accuracy: Double = 1e-9, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    /// 아이콘의 점(●)은 호 둘로 그린 원 — 시작점으로 돌아오고, 반원마다 90° 조각 둘 → 3차 베지어 4개. 조각 끝점은 모두 원 위.
    func testCircleFromTwoArcsReturnsToStart() throws {
        let d = "M11.1 6a0.9 0.9 0 1 0 1.8 0a0.9 0.9 0 1 0 -1.8 0Z"
        let commands = try XCTUnwrap(SVGPathData.parse(d))
        XCTAssertEqual(commands.first, .move(P(11.1, 6)))
        XCTAssertEqual(commands.last, .close)
        let segments = cubics(commands)
        XCTAssertGreaterThanOrEqual(segments.count, 2)
        XCTAssertEqual(segments.count, 4, "반원 둘 × 90° 조각 둘")
        assertClose(segments[1].2, P(12.9, 6), "첫 호의 끝")
        assertClose(try XCTUnwrap(segments.last).2, P(11.1, 6), "두 번째 호의 끝 = 시작점")
        for segment in segments {
            let dx = segment.2.x - 12, dy = segment.2.y - 6
            XCTAssertEqual((dx * dx + dy * dy).squareRoot(), 0.9, accuracy: 1e-9, "조각 끝점은 원 위")
        }
        // 첫 조각의 중간(t=0.5)도 원 위에 가깝다(90° 조각의 3차 근사 오차 < 0.03%).
        let (c1, c2, e) = segments[0]
        let s = P(11.1, 6)
        let mid = P(0.125 * s.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * e.x,
                    0.125 * s.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * e.y)
        XCTAssertEqual(((mid.x - 12) * (mid.x - 12) + (mid.y - 6) * (mid.y - 6)).squareRoot(), 0.9, accuracy: 0.001)
    }

    /// 상대(a)와 절대(A)는 같은 끝점이면 같은 결과. 반지름·각은 늘 그대로이고 끝점만 상대.
    func testRelativeAndAbsoluteArcsAgree() throws {
        let relative = try XCTUnwrap(SVGPathData.parse("M10 10a5 5 0 0 1 5 5"))
        let absolute = try XCTUnwrap(SVGPathData.parse("M10 10A5 5 0 0 1 15 15"))
        XCTAssertEqual(relative, absolute)
        XCTAssertEqual(cubics(relative).count, 1, "90° 호 = 조각 하나")
        assertClose(try XCTUnwrap(cubics(relative).last).2, P(15, 15))
        // 상대 호 뒤에 오는 상대 명령은 호의 끝점 기준.
        let chained = try XCTUnwrap(SVGPathData.parse("M10 10a5 5 0 0 1 5 5l1 0"))
        XCTAssertEqual(chained.last, .line(P(16, 15)))
    }

    /// large-arc·sweep 플래그는 네 가지 다른 호(제어점이 다르다). large-arc 는 조각 수도 다르다(270° → 3조각).
    func testFlagsPickDifferentArcs() throws {
        let variants = try ["0 0", "0 1", "1 0", "1 1"].map { flags in
            try XCTUnwrap(SVGPathData.parse("M10 10A5 5 0 \(flags) 15 15"))
        }
        for i in 0..<variants.count {
            for j in (i + 1)..<variants.count {
                XCTAssertNotEqual(variants[i], variants[j], "\(i) vs \(j)")
            }
        }
        XCTAssertEqual(cubics(variants[0]).count, 1)
        XCTAssertEqual(cubics(variants[1]).count, 1)
        XCTAssertEqual(cubics(variants[2]).count, 3)
        XCTAssertEqual(cubics(variants[3]).count, 3)
        for variant in variants {
            assertClose(try XCTUnwrap(cubics(variant).last).2, P(15, 15), "끝점은 플래그와 무관")
        }
        // sweep 만 다른 두 호는 중심이 양쪽에 있다 — 작은 호의 중간점이 끝점을 잇는 선의 서로 반대쪽.
        let a = cubics(variants[0])[0], b = cubics(variants[1])[0]
        let midA = 0.375 * (a.0.x + a.1.x) + 0.125 * (10 + 15), midB = 0.375 * (b.0.x + b.1.x) + 0.125 * (10 + 15)
        XCTAssertNotEqual(midA > 12.5, midB > 12.5)
    }

    /// 반지름 0 은 직선(명세 F.6.2). 시작점 = 끝점이면 조각이 없다.
    func testZeroRadiusIsALine() throws {
        XCTAssertEqual(SVGPathData.parse("M0 0a0 5 0 0 1 10 10"), [.move(P(0, 0)), .line(P(10, 10))])
        XCTAssertEqual(SVGPathData.parse("M0 0A5 0 0 0 1 10 10"), [.move(P(0, 0)), .line(P(10, 10))])
        XCTAssertEqual(SVGPathData.parse("M3 3a5 5 0 0 1 0 0"), [.move(P(3, 3))])
    }

    /// 같은 명령의 매개변수 반복(암묵적 반복) — 7개씩 끊어 읽고, 둘째 호는 첫 호의 끝점에서 시작한다.
    func testImplicitRepeat() throws {
        let commands = try XCTUnwrap(SVGPathData.parse("M0 0a1 1 0 0 1 2 0 1 1 0 0 1 2 0"))
        let segments = cubics(commands)
        XCTAssertEqual(segments.count, 4, "반원 둘 × 2조각")
        assertClose(segments[1].2, P(2, 0))
        assertClose(try XCTUnwrap(segments.last).2, P(4, 0))
        XCTAssertEqual(SVGPathData.parse("M0 0a1 1 0 0 1 2 0 1 1 0 0 1 2 0 1 1 0 0 1 2 0")?.count, 7)
    }

    /// 반지름이 끝점 사이 거리보다 작으면 키운다(F.6.6.2) — 끝점은 그대로, 지름 = 거리.
    func testTooSmallRadiusIsScaledUp() throws {
        let commands = try XCTUnwrap(SVGPathData.parse("M0 0A1 1 0 0 1 10 0"))
        let segments = cubics(commands)
        XCTAssertEqual(segments.count, 2)
        assertClose(try XCTUnwrap(segments.last).2, P(10, 0))
        // 가운데 조각 끝 = 반원의 꼭대기(중심 (5,0), 반지름 5). sweep=1 은 각이 커지는 쪽 — SVG(y 아래) 좌표에서 y 음수 쪽을 지난다.
        assertClose(segments[0].2, P(5, -5), accuracy: 1e-9)
        let sweptBack = cubics(try XCTUnwrap(SVGPathData.parse("M0 0A1 1 0 0 0 10 0")))
        assertClose(sweptBack[0].2, P(5, 5), accuracy: 1e-9, "sweep=0 은 반대쪽")
    }

    /// 회전한 타원 호: 끝점은 지키고 조각 끝점은 타원 위.
    func testRotatedEllipse() throws {
        let commands = try XCTUnwrap(SVGPathData.parse("M0 0A4 2 30 0 1 4 2"))
        let segments = cubics(commands)
        assertClose(try XCTUnwrap(segments.last).2, P(4, 2))
        XCTAssertFalse(segments.isEmpty)
    }

    /// 모자란 매개변수·엉뚱한 플래그는 nil(반쯤 그리지 않는다).
    func testMalformedArcIsRejected() {
        XCTAssertNil(SVGPathData.parse("M0 0A1 1 0 0 1 2"))
        XCTAssertNil(SVGPathData.parse("M0 0a1 1 0 2 0 2 2"))
        XCTAssertNil(SVGPathData.parse("M0 0a1 1 0 0 0.5 2 2"))
    }

    /// 아이콘 정본의 호 문장들(기기 몸체·지문 틀·벨·덮개)이 끝까지 읽힌다.
    func testIconArcStringsParse() throws {
        let strings = [
            "M8 3h8a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z",
            "M5 3.5h14a1.5 1.5 0 0 1 1.5 1.5v14a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 19V5A1.5 1.5 0 0 1 5 3.5Z",
            "M6 10a6 6 0 0 1 12 0v4l1.5 2.5h-15L6 14Z",
            "M10 19.5a2 2 0 0 0 4 0",
            "M4 16a8 8 0 0 1 16 0Z",
            "M5.199999999999999 18.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z",
        ]
        for d in strings {
            let commands = try XCTUnwrap(SVGPathData.parse(d), d)
            XCTAssertFalse(cubics(commands).isEmpty, d)
            for p in points(commands) {
                XCTAssertTrue((-1...25).contains(p.x) && (-1...25).contains(p.y), "\(d) → \(p)")
            }
        }
    }
}
