// 「한데」 모닥불 테마(#405 P2 → 디자인 1차 2026-10-31): 밤하늘 남색 위로 아래쪽 불빛이 번진다. 앱 아이콘과 같은 색 —
// 불(주황) · 사람(크림색 점 ●) · 에이전트(파란 점 ●, 낮불에서는 ◆). 밤 테마가 기본·고정(오너 결정)이고, 낮불(e-ink·밝은 곳)은
// 설정에서 고르는 별도 고대비 테마다 — 밤을 그대로 밝게 뒤집은 라이트 모드가 아니다(그라데이션·반투명·빛남·그림자 0).
// 토큰 정본: docs/design/hande-tokens.json (iOS·Android·한데 웹이 같은 값을 쓴다).
import SwiftUI
import FamilyMLSCore

/// 테마 모드 — 설정 「화면」. `UserDefaults.standard` 키 `hande.theme`(서버 스코프 밖: 기기 표시 설정).
enum HandeThemeMode: String, CaseIterable, Identifiable {
    case night, day
    var id: String { rawValue }
    static let storageKey = "hande.theme"
    /// 저장값이 없거나 모르는 값이면 밤.
    static func from(_ raw: String?) -> HandeThemeMode { raw.flatMap(HandeThemeMode.init(rawValue:)) ?? .night }
    var palette: HandePalette { self == .day ? .day : .night }
    var colorScheme: ColorScheme { self == .day ? .light : .dark }
}

/// 색 토큰 한 벌(밤 / 낮불). 뷰는 `@Environment(\.hande)` 로 받는다 — 정적 `Hande.*` 는 밤 값의 별칭(옛 호출부·오프닝).
struct HandePalette: Equatable {
    /// 배경 위(밤하늘 / 종이).
    let bgTop: Color
    /// 배경 아래 불빛 땅 — 낮불은 nil(그라데이션 금지).
    let bgGlow: Color?
    /// 불 · 1차 강조(주 버튼·내 말풍선·포커스). 낮불은 포인트 1색(허락·보내기만).
    let ember: Color
    let emberDeep: Color
    let onEmber: Color
    /// 사람 점 ●(크림 / 먹).
    let person: Color
    /// 에이전트 점·카드(파랑). 사람과 AI 를 색으로 구별하는 것은 제품 원칙 1번 — 어떤 화면에서도 바꾸지 않는다.
    let agent: Color
    /// 에이전트 라벨 글자(파랑 위 가독용).
    let agentText: Color
    let ink: Color
    let inkDim: Color
    /// 면(카드·남의 말풍선·입력창) / 선.
    let surface: Color
    let stroke: Color
    /// 상태 · 주의/실패(붉은 잉걸) — 반드시 글자와 함께. 빨강/초록 신호등 조합 금지.
    let warn: Color
    /// 상태 · 정지/꺼짐(꺼진 재).
    let ash: Color
    let focus: Color
    let isDay: Bool

    /// 선 굵기: 밤 1 · 낮불 1.5(e-ink 1px 끊김 방지).
    var lineWidth: CGFloat { isDay ? 1.5 : 1 }
    /// 빛남(그림자) 반경 배율 — 낮불 0.
    var glow: CGFloat { isDay ? 0 : 1 }
    /// 에이전트 카드·말풍선: 밤 fill 10% / stroke 35%, 낮불 흰 면 + 파랑 점선.
    var agentFill: Color { isDay ? surface : agent.opacity(0.10) }
    var agentStroke: Color { isDay ? agent : agent.opacity(0.35) }
    var agentDash: [CGFloat] { isDay ? [6, 4] : [] }

    // MARK: 디자인 2차-B B3 상태표(2026-10-31) — 비활성·눌림·주의 값. 낮불은 투명도 대신 점선 + 회색 #8A8178.

    /// 비활성 면: 낮불 종이(#F7F3EA) / 밤 불 18%(주 버튼 기준 — 보조·위험·크림의 밤 값은 `buttonFace`).
    var disabledFill: Color { isDay ? bgTop : ember.opacity(0.18) }
    /// 비활성 선: 낮불 1.5 점선 #8A8178 / 밤 없음.
    var disabledStroke: Color { isDay ? ash : .clear }
    /// 비활성 글자: 낮불 #8A8178 / 밤 먹 45%.
    var disabledText: Color { isDay ? ash : ink.opacity(0.45) }
    /// 비활성 점선 — 낮불만.
    var disabledDash: [CGFloat] { isDay ? [5, 4] : [] }
    /// 눌림 면(보조·크림 버튼·설정 행): 낮불 #E9E4DA / 밤 흰 13%.
    var pressedSurface: Color { isDay ? Color(hande: 0xE9E4DA) : Color.white.opacity(0.13) }
    /// 주의 글자: 밤 #F08A70(붉은 잉걸 위 가독) / 낮불 = warn.
    var warnText: Color { isDay ? warn : Color(hande: 0xF08A70) }
    /// 주의 선 굵기: 낮불 2 / 밤 1.5(위험 버튼·오류 입력칸·실패 말풍선·경고 상자).
    var warnLineWidth: CGFloat { isDay ? 2 : 1.5 }
    /// 표시된 지문 행 면: 낮불 #EFE9DC / 밤 불 8%.
    var tickedRowFill: Color { isDay ? Color(hande: 0xEFE9DC) : ember.opacity(0.08) }

    enum ButtonKind: CaseIterable { case primary, secondary, danger, cream }

    /// 버튼 4종의 기본/눌림/비활성 값(B3 상태표 `prim`/`sec`/`dan`/`crm` 그대로). 낮불 비활성은 넷 다 종이 + 1.5 점선 #8A8178 + 회색 글자.
    func buttonFace(_ kind: ButtonKind, pressed: Bool, enabled: Bool = true) -> HandeButtonFace {
        if !enabled && isDay {
            return HandeButtonFace(fill: bgTop, stroke: ash, text: ash, lineWidth: 1.5, dash: disabledDash)
        }
        switch kind {
        case .primary:
            // 낮불: #D97A1E + 1.5 먹 선 · 눌림 #B8650F / 밤: #F59E42 · 눌림 #E8833A · 비활성 면 18% + 글자 45%.
            guard enabled else { return HandeButtonFace(fill: ember.opacity(0.18), stroke: .clear, text: ink.opacity(0.45), lineWidth: 0) }
            return HandeButtonFace(fill: pressed ? emberDeep : ember, stroke: isDay ? stroke : .clear, text: onEmber, lineWidth: lineWidth)
        case .secondary:
            // 낮불: 흰 면 + 1.5 먹 · 눌림 #E9E4DA / 밤: 흰 7% + 선 14% · 눌림 흰 13% · 비활성 흰 4% + 글자 40%.
            guard enabled else { return HandeButtonFace(fill: Color.white.opacity(0.04), stroke: stroke, text: ink.opacity(0.4), lineWidth: lineWidth) }
            return HandeButtonFace(fill: pressed ? pressedSurface : surface, stroke: stroke, text: ink, lineWidth: lineWidth)
        case .danger:
            if isDay {
                // 흰 면 + 2px #A8321C + 글자 #A8321C · 눌림 = #A8321C 면 + 종이 글자.
                return HandeButtonFace(fill: pressed ? warn : surface, stroke: warn, text: pressed ? bgTop : warn, lineWidth: 2)
            }
            // 밤: 면 8% + 선 1.5 60% + 글자 #F08A70 · 눌림 면 22% + 선 100% + 글자 #FFD0C2 · 비활성 면 없음 + 선 25% + 글자 40%.
            guard enabled else { return HandeButtonFace(fill: .clear, stroke: warn.opacity(0.25), text: warnText.opacity(0.4), lineWidth: 1.5) }
            return HandeButtonFace(fill: warn.opacity(pressed ? 0.22 : 0.08), stroke: pressed ? warn : warn.opacity(0.6),
                                   text: pressed ? Color(hande: 0xFFD0C2) : warnText, lineWidth: 1.5)
        case .cream:
            if isDay {
                // 흰 면 + 2px 먹 + 먹 글자(한 화면 단일 행동용) · 눌림 #E9E4DA.
                return HandeButtonFace(fill: pressed ? pressedSurface : surface, stroke: stroke, text: ink, lineWidth: 2)
            }
            // 밤: #F3E6D3 · 눌림 #E3D3BA · 글자 #1B0F06 · 비활성 크림 18% + 글자 45%.
            guard enabled else { return HandeButtonFace(fill: ink.opacity(0.18), stroke: .clear, text: ink.opacity(0.45), lineWidth: 0) }
            return HandeButtonFace(fill: pressed ? Color(hande: 0xE3D3BA) : ink, stroke: .clear, text: onEmber, lineWidth: 0)
        }
    }

    static let night = HandePalette(
        bgTop: Color(hande: 0x0F1324), bgGlow: Color(hande: 0x5A2C12),
        ember: Color(hande: 0xF59E42), emberDeep: Color(hande: 0xE8833A), onEmber: Color(hande: 0x1B0F06),
        person: Color(hande: 0xFFD79A), agent: Color(hande: 0x61A6FA), agentText: Color(hande: 0x9CC8FF),
        ink: Color(hande: 0xF3E6D3), inkDim: Color(hande: 0xC9B89C),
        surface: Color.white.opacity(0.07), stroke: Color(hande: 0xFFBF78).opacity(0.14),
        warn: Color(hande: 0xD9583B), ash: Color(hande: 0x6B5A48), focus: Color(hande: 0xFFD79A),
        isDay: false)

    static let day = HandePalette(
        bgTop: Color(hande: 0xF7F3EA), bgGlow: nil,
        ember: Color(hande: 0xD97A1E), emberDeep: Color(hande: 0xB8650F), onEmber: Color(hande: 0x1A1510),
        person: Color(hande: 0x1A1510), agent: Color(hande: 0x2F6FC4), agentText: Color(hande: 0x2F6FC4),
        ink: Color(hande: 0x1A1510), inkDim: Color(hande: 0x3A322B),
        surface: Color.white, stroke: Color(hande: 0x1A1510),
        warn: Color(hande: 0xA8321C), ash: Color(hande: 0x8A8178), focus: Color(hande: 0x1A1510),
        isDay: true)
}

/// 버튼 한 상태의 면·선·글자(디자인 2차-B B3). `dash` 가 비어 있지 않으면 점선(낮불 비활성).
struct HandeButtonFace: Equatable {
    let fill: Color
    let stroke: Color
    let text: Color
    let lineWidth: CGFloat
    var dash: [CGFloat] = []
    var strokeStyle: StrokeStyle { StrokeStyle(lineWidth: lineWidth, dash: dash) }
}

extension Color {
    /// 토큰 JSON 의 `#RRGGBB` 그대로.
    init(hande hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

private struct HandePaletteKey: EnvironmentKey {
    static let defaultValue = HandePalette.night
}

extension EnvironmentValues {
    var hande: HandePalette {
        get { self[HandePaletteKey.self] }
        set { self[HandePaletteKey.self] = newValue }
    }
}

/// 밤 값의 정적 별칭 + 반경. 테마를 따라 바뀌어야 하는 뷰는 `@Environment(\.hande)` 를 쓴다.
enum Hande {
    static let night = HandePalette.night.bgTop
    static let glow = HandePalette.night.bgGlow ?? HandePalette.night.bgTop
    static let ember = HandePalette.night.ember
    static let emberDeep = HandePalette.night.emberDeep
    static let onEmber = HandePalette.night.onEmber
    static let cream = HandePalette.night.person
    static let agent = HandePalette.night.agent
    static let agentText = HandePalette.night.agentText
    static let ink = HandePalette.night.ink
    static let inkDim = HandePalette.night.inkDim
    static let surface = HandePalette.night.surface
    static let stroke = HandePalette.night.stroke
    static let warn = HandePalette.night.warn
    static let ash = HandePalette.night.ash
    /// 반경 S 10 / M 16 / L 24 (4pt 그리드).
    static let radiusS: CGFloat = 10
    static let radiusM: CGFloat = 16
    static let radiusL: CGFloat = 24
}

/// 화면 배경: 밤 남색 → 아래 가운데에서 번지는 불빛. 낮불은 종이 단색.
struct CampfireBackground: View {
    @Environment(\.hande) private var p
    var body: some View {
        ZStack {
            p.bgTop
            if let glow = p.bgGlow {
                RadialGradient(colors: [glow, glow.opacity(0.45), .clear],
                               center: .bottom, startRadius: 0, endRadius: 520)
            }
        }
        .ignoresSafeArea()
    }
}

/// 자리 점 하나: 사람 ● / 에이전트 ●(밤, 빛남) · ◆(낮불 — 회색 16단계 e-ink 에서도 모양으로 구별).
struct SeatDot: View {
    var agent = false
    var size: CGFloat = 8
    var dim = false
    @Environment(\.hande) private var p
    var body: some View {
        Group {
            if agent && p.isDay {
                Rectangle().fill(p.agent).frame(width: size * 0.8, height: size * 0.8).rotationEffect(.degrees(45))
                    .frame(width: size, height: size)
            } else if agent {
                Circle().fill(p.agent).frame(width: size, height: size)
                    .shadow(color: p.agent.opacity(0.8 * p.glow), radius: size / 3)
            } else {
                Circle().fill(p.person).frame(width: size, height: size)
            }
        }
        .opacity(dim ? 0.5 : 1)
        .accessibilityHidden(true)
    }
}

/// 둘러앉은 자리 점 나열: 사람 먼저, 에이전트 뒤. `RoomGlance.maxSeats` 까지만.
struct SeatDots: View {
    let people: Int
    let agents: Int
    var size: CGFloat = 8

    var body: some View {
        HStack(spacing: size / 2) {
            ForEach(0..<min(people, RoomGlance.maxSeats), id: \.self) { _ in SeatDot(size: size) }
            ForEach(0..<min(agents, max(0, RoomGlance.maxSeats - people)), id: \.self) { _ in SeatDot(agent: true, size: size) }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 한데 고유 UI 아이콘 세트(디자인 2차-B B2, 2026-10-31). path 정본은 HandeIconArt(docs/design/icons/ui/*.svg 그대로).

/// 아이콘 14종: 불 세기 1~3 · 꺼진 자리 · 불지기 · 지문(대조) · 기기 4종 · 자리 · 초대 벨 · 순서 편집 · 덮어 두기.
enum HandeIcon: Equatable, CaseIterable {
    case flame(Int)
    case embersOut, keeper, fingerprintRows, deviceIPhone, deviceAndroid, devicePC, deviceWeb, seat, inviteBell, reorder, cover

    static let allCases: [HandeIcon] = [.flame(1), .flame(2), .flame(3), .embersOut, .keeper, .fingerprintRows,
                                        .deviceIPhone, .deviceAndroid, .devicePC, .deviceWeb, .seat, .inviteBell, .reorder, .cover]

    /// 불꽃을 뺀 아이콘의 정본(선 + 역할색 채움). 불꽃은 `HandeIconArt.tongues`.
    var art: HandeIconArt.Icon? {
        switch self {
        case .flame: return nil
        case .embersOut: return HandeIconArt.embersOut
        case .keeper: return HandeIconArt.keeper
        case .fingerprintRows: return HandeIconArt.fingerprintRows
        case .deviceIPhone: return HandeIconArt.deviceIPhone
        case .deviceAndroid: return HandeIconArt.deviceAndroid
        case .devicePC: return HandeIconArt.devicePC
        case .deviceWeb: return HandeIconArt.deviceWeb
        case .seat: return HandeIconArt.seat
        case .inviteBell: return HandeIconArt.inviteBell
        case .reorder: return HandeIconArt.reorder
        case .cover: return HandeIconArt.cover
        }
    }

    /// 이 아이콘이 쓰는 path 문자열 전부(파서 검사용).
    var paths: [String] {
        if case .flame = self { return HandeIconArt.tongues.map(\.d) }
        return art?.paths ?? []
    }
}

/// 아이콘 그리기: 24 뷰박스를 `size` 로 비례, 선 1.6×배율 둥근 끝/모서리 `color ?? p.ink`. 역할색 채움은 팔레트
/// (밤: 불·깊은 불·크림·파랑·먹 / 낮불: ember·ember-deep·person·ink = 먹, agent = 파랑). 불꽃: 켜진 갈래 = 채움(낮불은 먹 채움 + 먹 선),
/// 꺼진 갈래 = 선만(밤 먹 35% / 낮불 먹). 낮불 `seat` 의 에이전트 점은 ◆. `dim` 은 불꽃을 재 색으로(꺼진 자리).
struct HandeIconView: View {
    let icon: HandeIcon
    var size: CGFloat = 24
    var color: Color? = nil
    var dim = false
    @Environment(\.hande) private var p

    init(_ icon: HandeIcon, size: CGFloat = 24, color: Color? = nil, dim: Bool = false) {
        self.icon = icon
        self.size = size
        self.color = color
        self.dim = dim
    }

    var body: some View {
        let scale = size / 24
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let line = StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
        ZStack {
            if case .flame(let level) = icon {
                ForEach(Array(HandeIconArt.tongues.enumerated()), id: \.offset) { _, tongue in
                    let path = OpeningArt.path(tongue.d).applying(transform)
                    if level >= tongue.litFrom {
                        path.fill(dim ? p.ash : fillColor(tongue.role))
                        if p.isDay {
                            path.stroke(dim ? p.ash : lineColor, style: line)
                        }
                    } else {
                        path.stroke(p.isDay ? lineColor : lineColor.opacity(0.35), style: line)
                    }
                }
            } else if let art = icon.art {
                ForEach(Array(art.strokes.enumerated()), id: \.offset) { _, d in
                    OpeningArt.path(d).applying(transform).stroke(lineColor, style: line)
                }
                ForEach(Array(art.fills.enumerated()), id: \.offset) { _, item in
                    OpeningArt.path(p.isDay ? (item.dayDiamond ?? item.d) : item.d).applying(transform).fill(fillColor(item.role))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var lineColor: Color { color ?? p.ink }

    private func fillColor(_ role: HandeIconArt.Role) -> Color {
        switch role {
        case .agent: return p.agent
        case .ink: return lineColor
        case .ember: return p.isDay ? p.ink : p.ember
        case .emberDeep: return p.isDay ? p.ink : p.emberDeep
        case .person: return p.isDay ? p.ink : p.person
        }
    }
}

/// 오늘의 불 세기(1~3단, 숫자 없음) — 목록 방 아이콘. 꺼진 자리는 재 색(`dim`). 이모지 🔥 대신 벡터(디자인 1차 1b → 2차-B 정본 불꽃).
struct FlameIcon: View {
    let level: Int
    var dim = false
    var size: CGFloat = 26

    /// 24×24 뷰박스의 불꽃 세 갈래(왼쪽·가운데·오른쪽, 정본 path) — 파서 검사용.
    static let tongues = HandeIconArt.tongues.map(\.d)

    var body: some View {
        HandeIconView(.flame(level), size: size, dim: dim)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.fireLevelLabel(level))
    }
}

/// 꺼진 자리 아이콘(엇갈린 장작 + 연기, 재 색) — 이모지 🪵 대신 벡터(2차-B `embers-out`).
struct LogIcon: View {
    var size: CGFloat = 24
    @Environment(\.hande) private var p
    var body: some View {
        HandeIconView(.embersOut, size: size, color: p.ash)
    }
}

/// hande 워드마크(오프닝·대화 목록 머리 공용): Questrial 윤곽(HandeWordmarkArt) · 크림색(낮불은 먹) · 은은한 불빛 번짐.
/// `size` 는 글자 크기(1em)와 같다 — 높이는 어센더까지 약 0.71em.
struct HandeWordmark: View {
    var size: CGFloat = 32
    @Environment(\.hande) private var p
    var body: some View {
        let scale = size / 1000
        HandeWordmarkShape()
            .fill(p.isDay ? p.ink : OpeningArt.wordmark)
            .frame(width: HandeWordmarkArt.width * scale, height: HandeWordmarkArt.height * scale)
            .shadow(color: p.ember.opacity(0.18 * p.glow), radius: size / 3)
            .accessibilityElement()
            .accessibilityLabel(Strings.appName)
    }
}

/// HandeWordmarkArt 윤곽을 주어진 칸에 비율 그대로 맞춘다.
struct HandeWordmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / HandeWordmarkArt.width, rect.height / HandeWordmarkArt.height)
        return OpeningArt.path(HandeWordmarkArt.d)
            .applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}

/// 주 버튼(불): 48pt · 반경 14 · 불 채움 · 불 위 글자(낮불 17/700 + 1.5 먹 선). 한 화면에 큰 주황 면은 1~2개.
/// 비활성(2차-B B3): 낮불 = 종이 면 + 1.5 **점선** #8A8178 + 회색 글자(투명도 0) / 밤 = 불 18% 면 + 먹 45% 글자.
struct HandePrimaryButtonStyle: ButtonStyle {
    @Environment(\.hande) private var p
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let face = p.buttonFace(.primary, pressed: configuration.isPressed, enabled: enabled)
        return configuration.label
            .font(.body.weight(p.isDay ? .bold : .semibold))
            .foregroundStyle(face.text)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(face.fill))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(face.stroke, style: face.strokeStyle))
    }
}

/// 보조 버튼(면 + 선): 눌림 낮불 #E9E4DA / 밤 흰 13% · 비활성 낮불 점선 / 밤 흰 4% + 글자 40%.
struct HandeSecondaryButtonStyle: ButtonStyle {
    @Environment(\.hande) private var p
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let face = p.buttonFace(.secondary, pressed: configuration.isPressed, enabled: enabled)
        return configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(face.text)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(face.fill))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(face.stroke, style: face.strokeStyle))
    }
}

// MARK: - 디자인 2차-A(2026-10-31) 공용 부품: 위험 버튼 · 배너 · 토스트 · 설정 카드.

// 위험 버튼 `HandeDangerButtonStyle`(46pt · 밤 warn 8% 면 + 1.5pt warn 60% 선 / 낮불 흰 면 + 2px warn)과 정적 점 3개 `DotsRow(color:size:)` 는
// 온보딩 부품(OnboardingKit.swift)에 있다 — 설정 「위험 구역」·배너·알림함도 같은 것을 쓴다. 상태별 값은 `HandePalette.buttonFace`(2차-B B3).

/// 한 줄 배너(방 화면 제목 아래 · 설정): 반경 12. info = 면 + 선, warn = 밤 붉은 잉걸 10% 면 + 45% 선 / 낮불 흰 면 + 2px #A8321C + 글자 600,
/// 앞에 작은 점 3개(정적).
struct HandeBanner: View {
    enum Kind: Equatable { case info, warn }
    let kind: Kind
    let text: String
    @Environment(\.hande) private var p

    init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    private var warnDay: Bool { kind == .warn && p.isDay }

    var body: some View {
        HStack(spacing: 10) {
            if kind == .warn { DotsRow(color: p.warn, size: 6) }
            Text(text).font(.subheadline.weight(warnDay ? .semibold : .regular)).foregroundStyle(p.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(kind == .warn && !p.isDay ? p.warn.opacity(0.10) : p.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(kind == .warn ? (p.isDay ? p.warn : p.warn.opacity(0.45)) : p.stroke,
                                                          lineWidth: warnDay ? 2 : p.lineWidth))
        .accessibilityElement(children: .combine)
    }
}

/// 토스트 한 줄(「복사했어요」): 아래 입력창 자리, 14pt, 2초 뒤 사라진다(`handeToast`).
/// 밤 = 면 #1C2136 + 선 #FFBF78 30% / 낮불 = 먹 면 + 종이 글자, 선 없음(2차-B B3).
struct HandeToast: View {
    let text: String
    @Environment(\.hande) private var p
    /// 밤 토스트 면 — 밤하늘보다 한 단 밝은 남색(토큰 JSON 밖, 디자인 2차 2e).
    static let nightFill = Color(hande: 0x1C2136)
    /// 밤 토스트 선 — 따뜻한 선 30%(「새 메시지」 알약과 같다).
    static let nightStroke = Color(hande: 0xFFBF78).opacity(0.3)
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(p.isDay ? p.bgTop : p.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(Capsule().fill(p.isDay ? p.ink : Self.nightFill))
            .overlay(Capsule().stroke(p.isDay ? Color.clear : Self.nightStroke, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.35 * p.glow), radius: 8, y: 4)
    }
}

/// `message` 가 생기면 아래에 토스트를 띄우고 `duration` 뒤 지운다(새 글이 오면 시간을 다시 센다).
struct HandeToastModifier: ViewModifier {
    @Binding var message: String?
    var duration: TimeInterval = 2
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    HandeToast(text: message)
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: message)
            .task(id: message) {
                guard message != nil else { return }
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                if !Task.isCancelled { message = nil }
            }
    }
}

extension View {
    func handeToast(_ message: Binding<String?>, duration: TimeInterval = 2) -> some View {
        modifier(HandeToastModifier(message: message, duration: duration))
    }
    /// 카드 면(면 + 따뜻한 선, 반경 16) — 알림함 카드·빈 상태 안내 카드·순서 행. `lineWidth` 를 주지 않으면 테마 선 굵기(밤 1 / 낮불 1.5).
    func handeCard(radius: CGFloat = Hande.radiusM, fill: Color? = nil, stroke: Color? = nil, lineWidth: CGFloat? = nil) -> some View {
        modifier(HandeCardModifier(radius: radius, fill: fill, stroke: stroke, lineWidth: lineWidth))
    }
}

struct HandeCardModifier: ViewModifier {
    var radius: CGFloat = Hande.radiusM
    var fill: Color? = nil
    var stroke: Color? = nil
    var lineWidth: CGFloat? = nil
    @Environment(\.hande) private var p
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(fill ?? p.surface))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(stroke ?? p.stroke, lineWidth: lineWidth ?? p.lineWidth))
    }
}

/// 설정 구역 머리(13/600 보조색 — 낮불 13/700, 여백 0 20 8).
struct SectionHeader: View {
    let text: String
    var color: Color? = nil
    @Environment(\.hande) private var p
    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.footnote.weight(p.isDay ? .bold : .semibold))
            .foregroundStyle(color ?? p.inkDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 설정 카드(반경 16 면 + 선) — 안은 `SectionRow` 를 세로로 쌓는다. 좌우 16pt 여백은 카드가 가진다.
struct SectionCard<Content: View>: View {
    private let content: Content
    @Environment(\.hande) private var p
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Hande.radiusM).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: Hande.radiusM).stroke(p.stroke, lineWidth: p.lineWidth))
            .clipShape(RoundedRectangle(cornerRadius: Hande.radiusM))
            .padding(.horizontal, 16)
    }
}

/// 설정 카드의 한 행(48pt 이상, 여백 10 16). 첫 행 뒤의 행은 위에 선 하나(`divider`).
struct SectionRow<Content: View>: View {
    private let divider: Bool
    private let content: Content
    @Environment(\.hande) private var p
    init(divider: Bool = true, @ViewBuilder content: () -> Content) {
        self.divider = divider
        self.content = content()
    }
    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(p.stroke).frame(height: p.lineWidth) }
            HStack(spacing: 12) { content }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }
}
