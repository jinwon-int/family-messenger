// 「한데」 모닥불 테마(#405 P2): 밤하늘 남색 위로 아래쪽 불빛이 번진다. 앱 아이콘과 같은 색 —
// 불(주황·노랑) · 사람(크림색 점) · 에이전트(파란 점). 밤 테마 고정(오너 결정) — 루트에서 .dark 로 묶는다.
import SwiftUI
import FamilyMLSCore

enum Hande {
    /// 밤하늘(배경 위쪽).
    static let night = Color(red: 0.059, green: 0.075, blue: 0.141)
    /// 불빛이 닿은 땅(배경 아래쪽).
    static let glow = Color(red: 0.353, green: 0.173, blue: 0.071)
    /// 불(버튼·내 말풍선).
    static let ember = Color(red: 0.961, green: 0.620, blue: 0.259)
    static let emberDeep = Color(red: 0.910, green: 0.514, blue: 0.227)
    /// 불빛 위 글자(내 말풍선 안).
    static let onEmber = Color(red: 0.106, green: 0.059, blue: 0.024)
    /// 사람 자리(크림색 점).
    static let cream = Color(red: 1.0, green: 0.843, blue: 0.604)
    /// 에이전트 자리(파란 점) — P1 AgentPalette 와 같은 색.
    static let agent = AgentPalette.accent
    /// 글자.
    static let ink = Color(red: 0.953, green: 0.902, blue: 0.827)
    static let inkDim = Color(red: 0.788, green: 0.722, blue: 0.612)
    /// 카드·남의 말풍선 바탕과 테두리.
    static let surface = Color.white.opacity(0.07)
    static let stroke = Color(red: 1.0, green: 0.75, blue: 0.47).opacity(0.14)
}

/// 화면 배경: 밤 남색 → 아래 가운데에서 번지는 불빛.
struct CampfireBackground: View {
    var body: some View {
        ZStack {
            Hande.night
            RadialGradient(colors: [Hande.glow, Hande.glow.opacity(0.45), .clear],
                           center: .bottom, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

/// 둘러앉은 자리 점: 사람 크림색, 에이전트 파란색(빛남).
struct SeatDots: View {
    let people: Int
    let agents: Int
    var size: CGFloat = 8

    var body: some View {
        HStack(spacing: size / 2) {
            ForEach(0..<min(people, RoomGlance.maxSeats), id: \.self) { _ in
                Circle().fill(Hande.cream).frame(width: size, height: size)
            }
            ForEach(0..<min(agents, max(0, RoomGlance.maxSeats - people)), id: \.self) { _ in
                Circle().fill(Hande.agent).frame(width: size, height: size).shadow(color: Hande.agent.opacity(0.8), radius: size / 3)
            }
        }
        .accessibilityHidden(true)
    }
}

/// HANDE 워드마크(오프닝·대화 목록 머리 공용): iOS 내장 Futura-Medium, 글자 크기의 1/3 자간, 따뜻한 빛 번짐.
struct HandeWordmark: View {
    var size: CGFloat = 32
    var body: some View {
        Text(Strings.wordmark)
            .font(.custom("Futura-Medium", size: size))
            .kerning(size / 3)
            .foregroundStyle(OpeningArt.wordmark)
            .shadow(color: Hande.ember.opacity(0.3), radius: size / 2.5)
            .accessibilityLabel(Strings.appName)
    }
}
