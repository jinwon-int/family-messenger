// 디자인 2차-A(2026-10-31) 온보딩·새 기기 승인 공용 조각(docs/design/HANDE-DESIGN-SYSTEM.md §A1~A2):
// 진행 막대 4칸(3px) · 화면 틀(배경 + 제목 28/600 + 아래 주 버튼) · 입력 칸 52pt/반경 14 · 카드 반경 16 · 「자세히」 접힘 · 지문 1열(행 42pt,
// 번호 13 + 모노 19, 승인 쪽은 표시 원 22pt) · 크림 면/위험 버튼 · 자리 점 순차 밝아짐(reduce motion 이면 전부 켜짐).
// 색은 전부 `@Environment(\.hande)` 토큰 — 정적 `Hande.*` 를 쓰지 않는다(낮불에서도 그대로 동작).
import SwiftUI
import FamilyMLSCore
#if canImport(UIKit)
import UIKit
#endif

/// 지문 hex → 화면 행. `SelfService.fingerprintGroups`(4자 묶음 16개)를 둘씩 짝지어 「xxxx xxxx」 8행 — 393×852 에 승인 버튼까지 들어가게.
/// 짧은 입력은 있는 만큼만(채우지 않는다). 등록 화면(EnrollView)과 승인 시트(CandidateApprovalView)가 같은 행을 같은 번호로 보인다.
enum FingerprintRows {
    static let perRow = 2

    static func make(_ hex: String) -> [String] {
        let groups = SelfService.fingerprintGroups(hex).split(separator: " ").map(String.init)
        var rows: [String] = []
        var index = 0
        while index < groups.count {
            let end = min(index + perRow, groups.count)
            rows.append(groups[index..<end].joined(separator: " "))
            index = end
        }
        return rows
    }
}

/// 상단 진행 막대: 4칸 · 3pt · 반경 2 · 켜짐 = 불, 꺼짐 = #FFBF78 18%.
struct StepBar: View {
    let step: Int
    let total: Int
    @Environment(\.hande) private var p

    init(step: Int, of total: Int = Strings.onboardingSteps) {
        self.step = step
        self.total = total
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(total, 0), id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < step ? p.ember : offColor)
                    .frame(height: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.onboardingStep(step, of: total))
    }

    private var offColor: Color { p.isDay ? p.ember.opacity(0.25) : Color(hande: 0xFFBF78).opacity(0.18) }
}

/// 온보딩 화면 틀: 모닥불 배경 + 진행 막대 + (뒤로 44pt) + (워드마크 30) + 제목 28/600 + 내용 + 아래 주 버튼 칸(12/24/하단).
struct OnboardingScreen<Content: View, Footer: View>: View {
    let step: Int
    let title: String?
    let wordmark: Bool
    let onBack: (() -> Void)?
    let content: Content
    let footer: Footer
    @Environment(\.hande) private var p

    init(step: Int, title: String?, wordmark: Bool = false, onBack: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.step = step
        self.title = title
        self.wordmark = wordmark
        self.onBack = onBack
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        ZStack {
            CampfireBackground()
            VStack(spacing: 0) {
                StepBar(step: step)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let onBack {
                            Button(action: onBack) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(p.isDay ? p.ink : p.ember)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, -12)
                            .accessibilityLabel(Strings.onboardingBack)
                        }
                        if wordmark { HandeWordmark(size: 30) }
                        if let title { OnboardingTitle(title) }
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                footer
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
            }
        }
    }
}

/// 화면 제목 28/600(`.title` 동적 글꼴).
struct OnboardingTitle: View {
    let text: String
    @Environment(\.hande) private var p
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.title.weight(.semibold))
            .foregroundStyle(p.ink)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 입력 칸 위 라벨 13/500 보조색.
struct FieldLabel: View {
    let text: String
    @Environment(\.hande) private var p
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(p.inkDim).padding(.horizontal, 4)
    }
}

/// 입력 칸: 52pt · 반경 14 · 면 + 선(밤 불 30% / 낮불 1.5 먹) · 모노 선택. 2차-B B3: 포커스 2px 포커스색(밤 #FFD79A / 낮불 먹),
/// 오류 = warn 선(낮불 2 / 밤 1.5) — 도움말 한 줄은 호출부가 `HandeFieldHelper` 로 밑에 둔다.
struct HandeField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var invalid = false
    var secure = false
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType? = nil
    var onSubmit: () -> Void = {}
    @Environment(\.hande) private var p
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .font(mono ? Font.system(size: 17, design: .monospaced) : Font.system(size: 17))
        .foregroundStyle(p.ink)
        .keyboardType(keyboard)
        .textContentType(contentType)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($focused)
        .onSubmit(onSubmit)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 14).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(strokeColor, lineWidth: strokeWidth))
    }

    private var strokeColor: Color {
        if invalid { return p.warn }
        if focused { return p.focus }
        return p.isDay ? p.stroke : p.ember.opacity(0.3)
    }
    private var strokeWidth: CGFloat {
        if invalid { return p.warnLineWidth }
        if focused { return 2 }
        return p.lineWidth
    }
}

/// 입력 칸 아래 오류 도움말 한 줄(12.5, warn) — 2차-B B3 「오류 2px #A8321C + 도움말 12.5」.
struct HandeFieldHelper: View {
    let text: String
    @Environment(\.hande) private var p
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(p.warn)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

/// 카드: 반경 16 · 면 + 선(기본 토큰, 선언 카드·오류 카드는 색을 넘긴다).
struct HandeCard<Content: View>: View {
    var padding: CGFloat = 14
    var fill: Color? = nil
    var stroke: Color? = nil
    var lineWidth: CGFloat? = nil
    let content: Content
    @Environment(\.hande) private var p

    init(padding: CGFloat = 14, fill: Color? = nil, stroke: Color? = nil, lineWidth: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.fill = fill
        self.stroke = stroke
        self.lineWidth = lineWidth
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Hande.radiusM).fill(fill ?? p.surface))
            .overlay(RoundedRectangle(cornerRadius: Hande.radiusM).stroke(stroke ?? p.stroke, lineWidth: lineWidth ?? p.lineWidth))
            .clipShape(RoundedRectangle(cornerRadius: Hande.radiusM))
    }
}

/// 1줄 안내 + 「자세히」(불 색 링크) → 누르면 아래 카드(14pt 보조색)가 펼쳐진다. 설명은 1줄 + 자세히 규칙(2차-A).
struct DetailDisclosure: View {
    var hint: String? = nil
    var hintSize: CGFloat = 14
    var label: String = Strings.onboardingMore
    let text: String
    @State private var expanded = false
    @Environment(\.hande) private var p

    init(hint: String? = nil, hintSize: CGFloat = 14, label: String = Strings.onboardingMore, text: String) {
        self.hint = hint
        self.hintSize = hintSize
        self.label = label
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let hint {
                    Text(hint).font(.system(size: hintSize)).foregroundStyle(p.inkDim).lineSpacing(3)
                }
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text(label)
                }
                .buttonStyle(HandeLinkButtonStyle(size: hintSize))
                .accessibilityAddTraits(expanded ? [.isSelected] : [])
            }
            .padding(.horizontal, 4)
            if expanded {
                HandeCard(padding: 12) {
                    Text(text).font(.system(size: 14)).foregroundStyle(p.inkDim).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 지문 1열: 행 42pt · 번호 Caption 13(28pt 칸) · 값 모노 19. `ticked` 를 주면 행마다 버튼 — 표시 원 22pt(빈 원 1.5px → 불 채움 + ✓),
/// 표시된 행 면 불 8%. 등록 화면(표시 없음)과 승인 시트(표시 있음)가 같은 행·같은 번호를 보인다(§A1 ①).
struct FingerprintList: View {
    let groups: [String]
    var ticked: Binding<Set<Int>>? = nil
    var disabled = false
    @Environment(\.hande) private var p

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, value in
                if index > 0 {
                    Rectangle().fill(p.stroke).frame(height: p.lineWidth)
                }
                row(index, value)
            }
        }
        .background(RoundedRectangle(cornerRadius: Hande.radiusM).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: Hande.radiusM).stroke(p.stroke, lineWidth: p.lineWidth))
        .clipShape(RoundedRectangle(cornerRadius: Hande.radiusM))
    }

    @ViewBuilder
    private func row(_ index: Int, _ value: String) -> some View {
        if let ticked {
            let on = ticked.wrappedValue.contains(index)
            Button {
                if ticked.wrappedValue.contains(index) {
                    ticked.wrappedValue.remove(index)
                } else {
                    ticked.wrappedValue.insert(index)
                }
            } label: {
                rowBody(index, value, tick: on)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(Strings.fingerprintRowLabel(index + 1, value, ticked: on))
        } else {
            rowBody(index, value, tick: nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Strings.fingerprintRowLabel(index + 1, value, ticked: nil))
        }
    }

    private func rowBody(_ index: Int, _ value: String, tick: Bool?) -> some View {
        HStack(spacing: 0) {
            Text("\(index + 1)")
                .font(.system(size: 13))
                .foregroundStyle(p.inkDim)
                .frame(width: 28, alignment: .leading)
            Text(value)
                .font(.system(size: 19, weight: tick == true && p.isDay ? .bold : .regular, design: .monospaced))
                .foregroundStyle(p.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            if let tick {
                TickCircle(on: tick)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
        // 표시된 행: 밤 불 8% / 낮불 #EFE9DC + hex 굵게(2차-B).
        .background(tick == true ? p.tickedRowFill : Color.clear)
        .contentShape(Rectangle())
    }
}

/// 표시 원 22pt: 빈 원(밤 먹 45% / 낮불 먹 · 1.5px) / 켜짐(밤 불 채움 + ✓ 불 위 글자 / 낮불 먹 채움 + 종이 ✓ — 주황 아님, 불은 주 버튼 1곳).
struct TickCircle: View {
    let on: Bool
    @Environment(\.hande) private var p
    var body: some View {
        ZStack {
            if on {
                Circle().fill(p.isDay ? p.ink : p.ember)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(p.isDay ? p.bgTop : p.onEmber)
            } else {
                Circle().stroke(p.isDay ? p.ink : p.ink.opacity(0.45), lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// 점 3개(정지 — #601: 움직이는 점은 일하는 중을 암시하므로 대기 문구 옆에는 고정).
struct DotsRow: View {
    let color: Color
    var size: CGFloat = 6
    var body: some View {
        HStack(spacing: size / 2) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(color).frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 자리 점이 차례로 밝아진다(오프닝 준비 중 · 불을 피우는 중). `agents[i]` = 그 자리가 에이전트(파랑)인지. reduce motion 이면 전부 켜진 채 고정.
struct SeatLoader: View {
    let agents: [Bool]
    var size: CGFloat = 8
    var interval: Double = 0.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || agents.isEmpty {
            row(lit: nil)
        } else {
            TimelineView(.periodic(from: .now, by: interval)) { timeline in
                let phase = Int(timeline.date.timeIntervalSinceReferenceDate / interval) % agents.count
                row(lit: phase)
                    .animation(.easeInOut(duration: interval * 0.6), value: phase)
            }
        }
    }

    private func row(lit: Int?) -> some View {
        HStack(spacing: size * 0.8) {
            ForEach(Array(agents.enumerated()), id: \.offset) { index, agent in
                SeatDot(agent: agent, size: size)
                    .opacity(lit == nil || lit == index ? 1 : 0.3)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 「불을 피우는 중…」(키 생성 중, §A2 ④ 상태 1): 진행 막대 4/4 + 자리 점 4개(크림·크림·파랑·크림, 12pt) 순차 + 22/600 + 15 보조.
struct KindlingView: View {
    @Environment(\.hande) private var p
    var body: some View {
        ZStack {
            CampfireBackground()
            VStack(spacing: 0) {
                StepBar(step: Strings.onboardingSteps)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                Spacer()
                SeatLoader(agents: [false, false, true, false], size: 12, interval: 0.4)
                Text(Strings.kindlingTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(p.ink)
                    .padding(.top, 18)
                Text(Strings.kindlingBody)
                    .font(.system(size: 15))
                    .foregroundStyle(p.inkDim)
                    .padding(.top, 8)
                Spacer()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.kindlingTitle + " " + Strings.kindlingBody)
    }
}

/// 크림 면 주 버튼(로그인 — 화면의 할 일이 하나라 주황 대신 크림 면 + 진한 글자): 밤 #F3E6D3 · 눌림 #E3D3BA / 낮불 흰 면 + 2px 먹 · 눌림 #E9E4DA
/// (2차-B B3 — 낮불의 주황은 허락·보내기·주 버튼만). 비활성: 밤 크림 18% + 글자 45% / 낮불 종이 + 점선.
struct HandeCreamButtonStyle: ButtonStyle {
    @Environment(\.hande) private var p
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let face = p.buttonFace(.cream, pressed: configuration.isPressed, enabled: enabled)
        return configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(face.text)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: Hande.radiusM).fill(face.fill))
            .overlay(RoundedRectangle(cornerRadius: Hande.radiusM).stroke(face.stroke, style: face.strokeStyle))
    }
}

/// 위험 버튼(「다릅니다」·「이 기기 지우기」) 46pt: 밤 면 warn 8% · 선 1.5 warn 60% · 글자 #F08A70 · 눌림 면 22% /
/// 낮불 흰 면 + 2px #A8321C · 글자 #A8321C · 눌림 = warn 면 + 종이 글자. 비활성: 밤 선 25% + 글자 40% / 낮불 종이 + 점선.
struct HandeDangerButtonStyle: ButtonStyle {
    @Environment(\.hande) private var p
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let face = p.buttonFace(.danger, pressed: configuration.isPressed, enabled: enabled)
        return configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(face.text)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(RoundedRectangle(cornerRadius: Hande.radiusM).fill(face.fill))
            .overlay(RoundedRectangle(cornerRadius: Hande.radiusM).stroke(face.stroke, style: face.strokeStyle))
    }
}

/// 작은 보조 버튼(기기 행의 지정/해제): 36pt · 반경 10 · 면 + 선(보조 버튼과 같은 상태 값).
struct HandeSmallSecondaryButtonStyle: ButtonStyle {
    @Environment(\.hande) private var p
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let face = p.buttonFace(.secondary, pressed: configuration.isPressed, enabled: enabled)
        return configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(face.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: Hande.radiusS).fill(face.fill))
            .overlay(RoundedRectangle(cornerRadius: Hande.radiusS).stroke(face.stroke, style: face.strokeStyle))
    }
}

/// 글자 링크(「등록 확인」·「다른 서버 선택」·「자세히」·설정의 「바꾸기」「복사」): 밤 = 불 색 500 / 낮불 = 먹 밑줄 600(색 대신 기호 — 2차-B).
struct HandeLinkButtonStyle: ButtonStyle {
    @Environment(\.hande) private var p
    var size: CGFloat = 15
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: p.isDay ? .semibold : .medium))
            .foregroundStyle(p.isDay ? p.ink : p.ember)
            .underline(p.isDay)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
