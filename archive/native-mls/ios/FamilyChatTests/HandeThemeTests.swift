import XCTest
import SwiftUI
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

    /// 벡터 아이콘의 path 가 파서(M/L/H/V/C/Q/Z)로 끝까지 읽힌다 — 반쯤 그려지는 일이 없게.
    func testIconPathsParse() throws {
        for d in FlameIcon.tongues {
            let commands = try XCTUnwrap(SVGPathData.parse(d), d)
            XCTAssertEqual(commands.last, .close)
        }
        XCTAssertNotNil(SVGPathData.parse("M6 14h12M6 18h12M6 14c-1.1 0-2 0.9-2 2c0 1.1 0.9 2 2 2M18 14c1.1 0 2 0.9 2 2c0 1.1-0.9 2-2 2M9 10l4-4M14 10l3-3"))
    }
}
