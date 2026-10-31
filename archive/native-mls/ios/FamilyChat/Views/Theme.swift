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

/// 오늘의 불 세기(1~3단, 숫자 없음) — 목록 방 아이콘. 꺼진 자리는 재 색. 이모지 🔥 대신 벡터(디자인 1차 1b).
struct FlameIcon: View {
    let level: Int
    var dim = false
    var size: CGFloat = 26
    @Environment(\.hande) private var p

    /// 24×24 뷰박스의 불꽃 세 갈래(디자인 원문 path).
    static let tongues = [
        "M7 20c0-4 3-6 3-9 1 2 2 3 2 5 0 2-2 4-5 4z",
        "M12 20c-3-2-4-6-1-11 1 3 3 4 3 7 0 2-1 3-2 4z",
        "M17 20c0-3-2-5-2-8 1 1 3 3 3 5 0 2-1 3-1 3z",
    ]

    var body: some View {
        let scale = size / 24
        ZStack {
            ForEach(Array(Self.tongues.enumerated()), id: \.offset) { index, d in
                OpeningArt.path(d)
                    .applying(CGAffineTransform(scaleX: scale, y: scale))
                    .fill(fill(index))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Strings.fireLevelLabel(level))
    }

    private func fill(_ index: Int) -> Color {
        guard index < level else { return p.ink.opacity(0.12) }
        if dim { return p.ash }
        return index == 1 ? p.ember : p.emberDeep
    }
}

/// 꺼진 자리의 장작 아이콘(이모지 🪵 대신 벡터).
struct LogIcon: View {
    var size: CGFloat = 24
    @Environment(\.hande) private var p
    var body: some View {
        let scale = size / 24
        ZStack {
            // 장작 두 토막(둥근 양 끝) + 위로 삐친 가지 둘.
            // SVGPathData 는 M/L/H/V/C/Q/Z 만 읽는다(S/A 없음) — 둥근 끝은 c 두 번.
            OpeningArt.path("M6 14h12M6 18h12M6 14c-1.1 0-2 0.9-2 2c0 1.1 0.9 2 2 2M18 14c1.1 0 2 0.9 2 2c0 1.1-0.9 2-2 2M9 10l4-4M14 10l3-3")
                .applying(CGAffineTransform(scaleX: scale, y: scale))
                .stroke(p.ash, style: StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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

/// 주 버튼(불): 48pt · 반경 14 · 불 채움 · 불 위 글자. 한 화면에 큰 주황 면은 1~2개.
struct HandePrimaryButtonStyle: ButtonStyle {
    @Environment(\.hande) private var p
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(p.onEmber)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(configuration.isPressed ? p.emberDeep : p.ember))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.isDay ? p.stroke : .clear, lineWidth: p.lineWidth))
            .opacity(enabled ? 1 : 0.45)
    }
}

/// 보조 버튼(면 + 선).
struct HandeSecondaryButtonStyle: ButtonStyle {
    @Environment(\.hande) private var p
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(p.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(configuration.isPressed ? p.stroke : p.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.stroke, lineWidth: p.lineWidth))
            .opacity(enabled ? 1 : 0.45)
    }
}

/// 둥근 알약 주 버튼(목록 아래 「불 피우기」): 52pt · 반경 26 · 불빛 번짐(밤).
struct HandePillButtonStyle: ButtonStyle {
    @Environment(\.hande) private var p
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(p.onEmber)
            .padding(.horizontal, 28)
            .frame(minHeight: 52)
            .background(Capsule().fill(configuration.isPressed ? p.emberDeep : p.ember))
            .overlay(Capsule().stroke(p.isDay ? p.stroke : .clear, lineWidth: p.lineWidth))
            .shadow(color: p.ember.opacity(0.25 * p.glow), radius: 14)
            .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - 디자인 2차-A(2026-10-31) 공용 부품: 위험 버튼 · 배너 · 토스트 · 설정 카드.

// 위험 버튼 `HandeDangerButtonStyle`(46pt · warn 8% 면 + 1.5pt warn 60% 선 + warn 글자)과 정적 점 3개 `DotsRow(color:size:)` 는
// 온보딩 부품(OnboardingKit.swift)에 있다 — 설정 「위험 구역」·배너·알림함도 같은 것을 쓴다.

/// 한 줄 배너(방 화면 제목 아래 · 설정): 반경 12. info = 면 + 선, warn = 붉은 잉걸 10% 면 + 45% 선 + 앞에 작은 점 3개(정적).
struct HandeBanner: View {
    enum Kind: Equatable { case info, warn }
    let kind: Kind
    let text: String
    @Environment(\.hande) private var p

    init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        HStack(spacing: 10) {
            if kind == .warn { DotsRow(color: p.warn, size: 6) }
            Text(text).font(.subheadline).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(kind == .warn ? p.warn.opacity(0.10) : p.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(kind == .warn ? p.warn.opacity(0.45) : p.stroke, lineWidth: p.lineWidth))
        .accessibilityElement(children: .combine)
    }
}

/// 토스트 한 줄(「복사했어요」): 아래 입력창 자리, 면 #1C2136(밤)/종이 면(낮불) + 선, 14pt. 2초 뒤 사라진다(`handeToast`).
struct HandeToast: View {
    let text: String
    @Environment(\.hande) private var p
    /// 밤 토스트 면 — 밤하늘보다 한 단 밝은 남색(토큰 JSON 밖, 디자인 2차 2e).
    static let nightFill = Color(hande: 0x1C2136)
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(p.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(Capsule().fill(p.isDay ? p.surface : Self.nightFill))
            .overlay(Capsule().stroke(p.stroke, lineWidth: p.lineWidth))
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
    /// 카드 면(면 + 따뜻한 선, 반경 16) — 알림함 카드·빈 상태 안내 카드·순서 행.
    func handeCard(radius: CGFloat = Hande.radiusM, fill: Color? = nil, stroke: Color? = nil) -> some View {
        modifier(HandeCardModifier(radius: radius, fill: fill, stroke: stroke))
    }
}

struct HandeCardModifier: ViewModifier {
    var radius: CGFloat = Hande.radiusM
    var fill: Color? = nil
    var stroke: Color? = nil
    @Environment(\.hande) private var p
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(fill ?? p.surface))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(stroke ?? p.stroke, lineWidth: p.lineWidth))
    }
}

/// 설정 구역 머리(13/600 보조색, 여백 0 20 8).
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
            .font(.footnote.weight(.semibold))
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
