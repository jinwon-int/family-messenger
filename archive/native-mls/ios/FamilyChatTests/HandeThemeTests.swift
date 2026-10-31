import XCTest
import SwiftUI
import FamilyMLSCore
@testable import FamilyChat

/// 디자인 1차(2026-10-31) 테마: 밤이 기본·고정, 낮불은 설정에서 고르는 별도 고대비 테마. 토큰 정본 docs/design/hande-tokens.json.
final class HandeThemeTests: XCTestCase {
    func testNightIsTheDefaultAndUnknownValuesFallBack() {
        XCTAssertEqual(HandeThemeMode.from(nil), .night)
        XCTAssertEqual(HandeThemeMode.from(""), .night)
        XCTAssertEqual(HandeThemeMode.from("light"), .night, "밤을 뒤집은 라이트 모드는 없다 — 낮불만")
        XCTAssertEqual(HandeThemeMode.from("day"), .day)
        XCTAssertEqual(HandeThemeMode.storageKey, "hande.theme")
    }

    func testDayThemeIsFlatAndHighContrast() {
        let day = HandePalette.day, night = HandePalette.night
        XCTAssertNil(day.bgGlow, "낮불: 그라데이션 금지")
        XCTAssertNotNil(night.bgGlow)
        XCTAssertEqual(day.lineWidth, 1.5, "e-ink 1px 끊김 방지")
        XCTAssertEqual(night.lineWidth, 1)
        XCTAssertEqual(day.glow, 0, "낮불: 빛남·그림자 0")
        XCTAssertEqual(day.agentDash, [6, 4], "낮불 에이전트는 점선 — 회색 16단계에서도 모양으로 구별")
        XCTAssertTrue(night.agentDash.isEmpty)
        XCTAssertEqual(HandeThemeMode.day.colorScheme, .light)
        XCTAssertEqual(HandeThemeMode.night.colorScheme, .dark)
    }

    /// 정적 별칭 `Hande.*` 는 밤 팔레트와 같은 값이다(옛 호출부·오프닝이 쓴다).
    func testStaticAliasesMatchTheNightPalette() {
        XCTAssertEqual(Hande.ember, HandePalette.night.ember)
        XCTAssertEqual(Hande.agent, HandePalette.night.agent)
        XCTAssertEqual(Hande.cream, HandePalette.night.person)
        XCTAssertEqual(AgentPalette.accent, Hande.agent)
        XCTAssertEqual(Hande.radiusS, 10)
        XCTAssertEqual(Hande.radiusM, 16)
        XCTAssertEqual(Hande.radiusL, 24)
    }

    /// 벡터 아이콘의 path 가 파서(M/L/H/V/C/Q/A/Z)로 끝까지 읽힌다 — 반쯤 그려지는 일이 없게. 2차-B 정본(HandeIconArt)은 호(`a`)를 쓴다.
    func testIconPathsParse() throws {
        XCTAssertEqual(FlameIcon.tongues.count, 3)
        for d in FlameIcon.tongues {
            let commands = try XCTUnwrap(SVGPathData.parse(d), d)
            XCTAssertEqual(commands.last, .close)
        }
        XCTAssertEqual(HandeIconArt.icons.count, 11)
        XCTAssertFalse(HandeIconArt.allPaths.isEmpty)
        for d in HandeIconArt.allPaths {
            let commands = try XCTUnwrap(SVGPathData.parse(d), d)
            XCTAssertFalse(commands.isEmpty, d)
            // 24 뷰박스 안(제어점 포함).
            for command in commands {
                switch command {
                case .move(let a), .line(let a):
                    XCTAssertTrue((0...24).contains(a.x) && (0...24).contains(a.y), "\(d) → \(a)")
                case .cubic(let c1, let c2, let e):
                    for a in [c1, c2, e] { XCTAssertTrue((-0.5...24.5).contains(a.x) && (-0.5...24.5).contains(a.y), "\(d) → \(a)") }
                case .quad(let q, let e):
                    for a in [q, e] { XCTAssertTrue((0...24).contains(a.x) && (0...24).contains(a.y), "\(d) → \(a)") }
                case .close: break
                }
            }
        }
        XCTAssertNotNil(SVGPathData.parse(EmptyCampfireArt.logs))
    }
}
