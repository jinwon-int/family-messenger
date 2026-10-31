import XCTest
import SwiftUI
import FamilyMLSCore
@testable import FamilyChat

/// 디자인 2차-B(2026-10-31): 한데 고유 UI 아이콘 세트(B2) · 낮불 세부(B1) · 컴포넌트 상태표(B3)의 값(순수 값만 — 그리기는 CI 의 컴파일로 확인).
final class DesignRound2BTests: XCTestCase {
    /// B2: 아이콘 14종(불 세기 3 + 11) — 모두 path 가 있고, 파서가 끝까지 읽는다(호 `a` 포함).
    func testEveryIconParses() throws {
        XCTAssertEqual(HandeIcon.allCases.count, 14)
        for icon in HandeIcon.allCases {
            XCTAssertFalse(icon.paths.isEmpty, "\(icon)")
            for d in icon.paths {
                let commands = try XCTUnwrap(SVGPathData.parse(d), "\(icon): \(d)")
                XCTAssertFalse(commands.isEmpty)
            }
        }
        // 호를 쓰는 아이콘은 베지어로 바뀌어 나온다(기기 몸체·지문 틀·벨·덮개·점).
        for icon in [HandeIcon.deviceIPhone, .fingerprintRows, .inviteBell, .cover, .seat, .embersOut, .keeper, .deviceAndroid] {
            let hasCubic = icon.paths.contains { d in
                (SVGPathData.parse(d) ?? []).contains { if case .cubic = $0 { return true } else { return false } }
            }
            XCTAssertTrue(hasCubic, "\(icon)")
        }
        XCTAssertEqual(HandeIconArt.icons.map(\.id), ["hande.embers-out", "hande.keeper", "hande.fingerprint-rows", "hande.device-iphone",
                                                     "hande.device-android", "hande.device-pc", "hande.device-web", "hande.seat",
                                                     "hande.invite-bell", "hande.reorder", "hande.cover"])
    }

    /// B2 불 세기: 켜진 갈래 수 = 단계(1 = 가운데, 2 = 가운데+왼쪽, 3 = 모두). 갈래 역할색은 가운데 ember · 양옆 ember-deep.
    func testFlameTonguesLightUpByLevel() {
        let tongues = HandeIconArt.tongues
        XCTAssertEqual(tongues.count, 3)
        XCTAssertEqual(tongues.map(\.litFrom), [2, 1, 3])
        XCTAssertEqual(tongues.map(\.role), [.emberDeep, .ember, .emberDeep])
        for level in 1...3 {
            XCTAssertEqual(tongues.filter { level >= $0.litFrom }.count, level, "level \(level)")
        }
        XCTAssertEqual(FlameIcon.tongues, tongues.map(\.d))
        XCTAssertEqual(HandeIcon.flame(2).paths, FlameIcon.tongues)
        XCTAssertNil(HandeIcon.flame(1).art)
    }

    /// B2: 역할색 채움 — 사람·에이전트 점은 `seat` 에만, 낮불의 에이전트 점은 ◆ 로 바꿔 그린다. 불지기의 불티는 파랑(agent).
    func testRoleFills() {
        let seat = HandeIconArt.seat
        XCTAssertEqual(seat.fills.map(\.role), [.person, .agent, .person, .agent, .person], "크림·파랑 교대 5점")
        XCTAssertEqual(seat.fills.compactMap(\.dayDiamond).count, 2)
        for fill in seat.fills {
            XCTAssertEqual(fill.dayDiamond != nil, fill.role == .agent)
        }
        XCTAssertEqual(HandeIconArt.keeper.fills.map(\.role), [.agent])
        XCTAssertEqual(HandeIconArt.deviceAndroid.fills.map(\.role), [.ink])
        let strokeOnly: [HandeIconArt.Icon] = [HandeIconArt.embersOut, HandeIconArt.fingerprintRows, HandeIconArt.deviceIPhone,
                                               HandeIconArt.devicePC, HandeIconArt.deviceWeb, HandeIconArt.inviteBell,
                                               HandeIconArt.reorder, HandeIconArt.cover]
        for icon in strokeOnly {
            XCTAssertTrue(icon.fills.isEmpty, icon.id)
        }
        _ = HandeIconView(.seat, size: 48)
        _ = HandeIconView(.flame(3), size: 26, color: nil, dim: true)
        _ = LogIcon(size: 24)
    }

    /// B3 비활성: 낮불 = 종이 면 + 점선 #8A8178 + 회색 글자(투명도 0) / 밤 = 불 18% 면 + 먹 45% 글자.
    func testDisabledTokens() {
        let day = HandePalette.day, night = HandePalette.night
        XCTAssertEqual(day.disabledFill, day.bgTop)
        XCTAssertEqual(day.disabledStroke, day.ash)
        XCTAssertEqual(day.disabledText, day.ash)
        XCTAssertEqual(day.disabledDash, [5, 4])
        XCTAssertEqual(day.ash, Color(hande: 0x8A8178))
        XCTAssertEqual(night.disabledFill, night.ember.opacity(0.18))
        XCTAssertEqual(night.disabledText, night.ink.opacity(0.45))
        XCTAssertEqual(night.disabledStroke, .clear)
        XCTAssertTrue(night.disabledDash.isEmpty)
        // 낮불은 네 버튼 모두 같은 비활성(점선) — 밤은 종류별 값.
        for kind in HandePalette.ButtonKind.allCases {
            let face = day.buttonFace(kind, pressed: false, enabled: false)
            XCTAssertEqual(face.fill, day.bgTop, "\(kind)")
            XCTAssertEqual(face.stroke, day.ash, "\(kind)")
            XCTAssertEqual(face.text, day.ash, "\(kind)")
            XCTAssertEqual(face.lineWidth, 1.5, "\(kind)")
            XCTAssertEqual(face.dash, [5, 4], "\(kind)")
            XCTAssertTrue(night.buttonFace(kind, pressed: false, enabled: false).dash.isEmpty, "\(kind)")
        }
        let nightPrimaryOff = night.buttonFace(.primary, pressed: false, enabled: false)
        XCTAssertEqual(nightPrimaryOff.fill, night.ember.opacity(0.18))
        XCTAssertEqual(nightPrimaryOff.text, night.ink.opacity(0.45))
        XCTAssertEqual(night.buttonFace(.secondary, pressed: false, enabled: false).fill, Color.white.opacity(0.04))
        XCTAssertEqual(night.buttonFace(.danger, pressed: false, enabled: false).stroke, night.warn.opacity(0.25))
        XCTAssertEqual(night.buttonFace(.cream, pressed: false, enabled: false).fill, night.ink.opacity(0.18))
    }

    /// B3 눌림: 주 = 깊은 불(#B8650F / #E8833A) · 보조·크림 낮불 #E9E4DA, 밤 흰 13% / 크림 밤 #E3D3BA · 위험 낮불 warn 면 + 종이 글자, 밤 22% + #FFD0C2.
    func testPressedTokens() {
        let day = HandePalette.day, night = HandePalette.night
        XCTAssertEqual(day.pressedSurface, Color(hande: 0xE9E4DA))
        XCTAssertEqual(night.pressedSurface, Color.white.opacity(0.13))
        XCTAssertEqual(day.buttonFace(.primary, pressed: true).fill, Color(hande: 0xB8650F))
        XCTAssertEqual(night.buttonFace(.primary, pressed: true).fill, Color(hande: 0xE8833A))
        XCTAssertEqual(day.buttonFace(.primary, pressed: false).fill, Color(hande: 0xD97A1E))
        XCTAssertEqual(day.buttonFace(.primary, pressed: false).stroke, day.ink, "낮불 주 버튼 1.5 먹 선")
        XCTAssertEqual(night.buttonFace(.primary, pressed: false).stroke, .clear)
        XCTAssertEqual(day.buttonFace(.secondary, pressed: true).fill, day.pressedSurface)
        XCTAssertEqual(night.buttonFace(.secondary, pressed: true).fill, night.pressedSurface)
        XCTAssertEqual(day.buttonFace(.danger, pressed: true).fill, day.warn)
        XCTAssertEqual(day.buttonFace(.danger, pressed: true).text, day.bgTop)
        XCTAssertEqual(day.buttonFace(.danger, pressed: false).fill, day.surface)
        XCTAssertEqual(day.buttonFace(.danger, pressed: false).lineWidth, 2)
        XCTAssertEqual(night.buttonFace(.danger, pressed: true).fill, night.warn.opacity(0.22))
        XCTAssertEqual(night.buttonFace(.danger, pressed: true).text, Color(hande: 0xFFD0C2))
        XCTAssertEqual(night.buttonFace(.danger, pressed: false).text, Color(hande: 0xF08A70))
        XCTAssertEqual(day.buttonFace(.cream, pressed: true).fill, day.pressedSurface)
        XCTAssertEqual(day.buttonFace(.cream, pressed: false).fill, day.surface, "낮불 크림 = 흰 면 + 2px 먹(불은 주 버튼만)")
        XCTAssertEqual(day.buttonFace(.cream, pressed: false).lineWidth, 2)
        XCTAssertEqual(night.buttonFace(.cream, pressed: true).fill, Color(hande: 0xE3D3BA))
        XCTAssertEqual(night.buttonFace(.cream, pressed: false).fill, Color(hande: 0xF3E6D3))
    }

    /// B3 주의·오류·표시: 선 굵기 낮불 2 / 밤 1.5 · 주의 글자 밤 #F08A70 · 표시된 지문 행 낮불 #EFE9DC / 밤 불 8% · 토스트 밤 선 30%.
    func testWarnAndTickTokens() {
        let day = HandePalette.day, night = HandePalette.night
        XCTAssertEqual(day.warnLineWidth, 2)
        XCTAssertEqual(night.warnLineWidth, 1.5)
        XCTAssertEqual(day.warnText, day.warn)
        XCTAssertEqual(night.warnText, Color(hande: 0xF08A70))
        XCTAssertEqual(day.tickedRowFill, Color(hande: 0xEFE9DC))
        XCTAssertEqual(night.tickedRowFill, night.ember.opacity(0.08))
        XCTAssertEqual(HandeToast.nightFill, Color(hande: 0x1C2136))
        XCTAssertEqual(HandeToast.nightStroke, Color(hande: 0xFFBF78).opacity(0.3))
        XCTAssertEqual(HandeButtonFace(fill: .clear, stroke: .clear, text: .clear, lineWidth: 1.5, dash: [5, 4]).strokeStyle.dash, [5, 4])
        _ = HandeFieldHelper(Strings.actorStepInvalid)
        XCTAssertEqual(Strings.unreadPill, "새 글")
    }
}
