// 오프닝 화면(#414): 밤하늘 아래 모닥불가에 사람 셋과 에이전트 하나가 둘러앉은 장면 + hande 워드마크.
// 그림은 시안(/root/hande-ui/make_opening_v5.py, 오너 선택 A v5 + 워드마크 B)과 같은 360×760 설계 좌표·path 문자열을 쓴다 —
// Core `SVGPathData` 가 path 를 해석하고, 여기서는 Canvas 로 칠하기만 한다. 불꽃은 흔들리고 불티는 오른다(TimelineView).
// 앱이 시작해서 첫 동기화 한 바퀴가 끝날 때까지 보인다(RootView) — 그 사이 `.needsEnrollment` 가 「이 기기 등록」으로 스치지 않게.
import SwiftUI
import FamilyMLSCore

struct OpeningView: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [OpeningArt.skyTop, OpeningArt.skyMid, OpeningArt.skyBottom],
                               startPoint: .top, endPoint: .bottom)
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    Canvas { context, size in
                        OpeningArt.draw(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
                VStack(spacing: 0) {
                    Spacer().frame(height: geo.size.height * 0.30)
                    HandeWordmark(size: 42)
                    Text(Strings.openingKorean)
                        .font(.footnote.weight(.medium))
                        .kerning(8)
                        .padding(.leading, 8)
                        .foregroundStyle(OpeningArt.koreanMark)
                        .padding(.top, 14)
                    Text(Strings.openingTagline)
                        .font(.footnote)
                        .foregroundStyle(OpeningArt.tagline)
                        .padding(.top, 10)
                    LoadingEmbers().padding(.top, 22)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.openingAccessibility)
    }
}

/// 준비 중 표시: 불씨 세 개가 차례로 밝아진다.
private struct LoadingEmbers: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { timeline in
            let phase = Int(timeline.date.timeIntervalSinceReferenceDate / 0.45) % 3
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Hande.ember).frame(width: 6, height: 6).opacity(i == phase ? 0.95 : 0.35)
                }
            }
        }
    }
}

/// 오프닝 그림(설계 좌표 360×760, 아래쪽 정렬로 화면을 채운다).
enum OpeningArt {
    static let skyTop = rgb(0x0a0f24), skyMid = rgb(0x151431), skyBottom = rgb(0x2a1610)
    static let wordmark = rgb(0xf8ead3), koreanMark = rgb(0xe8b678), tagline = rgb(0xcdb8a0)

    static let designSize = CGSize(width: 360, height: 760)

    // ── 인물(오른쪽을 보고 통나무에 앉은 자세, 앉은 자리 = 원점) ──
    static let torso = "M14 0 C10 -20 12 -46 22 -62 C28 -70 38 -72 46 -68 C52 -64 54 -56 52 -48 C50 -38 44 -24 40 0 Z"
    static let leg = "M28 -4 C40 -10 56 -22 66 -31 C70 -34 76 -32 77 -27 C79 -17 80 -8 83 0 L71 0 C70 -8 69 -14 67 -18 C58 -12 46 -4 36 0 Z"
    static let arm = "M45 -61 C51 -49 58 -39 68 -31"
    static let head = (x: 42.0, y: -84.0, r: 11.0)
    static let nose = (x: 52.5, y: -83.5, r: 2.4)
    static let blanket = "M13 -50 C16 -64 30 -73 44 -69 C40 -56 36 -30 34 0 L15 0 C12 -18 11 -36 13 -50 Z"
    enum Hair {
        case bun, short, long
        var path: String {
            switch self {
            case .bun: return "M31 -85 C30 -98 45 -101 52 -91 C45 -93 39 -90 35 -80 Z"
            case .short: return "M30 -84 C29 -98 46 -101 53 -90 C47 -91 41 -89 37 -82 C35 -80 32 -80 30 -84 Z"
            case .long: return "M30 -82 C28 -99 47 -101 53 -90 C46 -92 41 -90 38 -84 C37 -76 36 -68 33 -62 C30 -66 29 -74 30 -82 Z"
            }
        }
    }
    static let mugHandle = "M58 -44 q-4.5 1 0 5.5"
    static let steam = "M60 -52 q-3 -6 1 -11 M64 -52 q-3 -6 1 -11"

    // ── 모닥불 ──
    static let sticks = "M154 652 l52 -11 M154 641 l52 11"
    static let flames: [(String, Color)] = [
        ("M180 560 C203 594 209 615 201 636 C195 649 165 649 159 636 C151 615 159 594 180 560z", rgb(0xf07a2c)),
        ("M164 588 C178 607 176 624 171 639 C165 646 155 639 155 628 C153 614 159 602 164 588z", rgb(0xe8642a)),
        ("M196 586 C207 607 207 624 201 637 C196 646 186 641 188 627 C190 614 194 600 196 586z", rgb(0xe8642a)),
        ("M180 594 C192 613 194 627 188 639 C185 646 175 646 172 639 C166 627 170 613 180 594z", rgb(0xffc554)),
    ]

    static let stars: [(Double, Double, Double, Double)] = [
        (40, 70, 1.2, 0.7), (95, 40, 0.9, 0.5), (150, 95, 1.1, 0.6), (230, 55, 1.4, 0.8), (300, 90, 1, 0.5), (330, 40, 1.2, 0.7),
        (270, 140, 0.8, 0.4), (60, 150, 0.9, 0.5), (200, 170, 1, 0.45), (120, 200, 0.7, 0.35), (315, 210, 1, 0.5), (25, 250, 0.8, 0.4),
    ]

    /// 설계 좌표 → 화면: 가로를 채우고(필요하면 세로도) 아래쪽을 맞춘다.
    static func fit(_ size: CGSize) -> (scale: CGFloat, dx: CGFloat, dy: CGFloat) {
        let s = max(size.width / designSize.width, size.height / designSize.height)
        return (s, (size.width - designSize.width * s) / 2, size.height - designSize.height * s)
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let f = fit(size)
        context.translateBy(x: f.dx, y: f.dy)
        context.scaleBy(x: f.scale, y: f.scale)

        for (x, y, r, o) in stars {
            context.fill(circle(x, y, r), with: .color(.white.opacity(o)))
        }
        context.fill(circle(285, 118, 16), with: .color(rgb(0xf5e6c8).opacity(0.9)))
        context.fill(circle(292, 113, 15), with: .color(rgb(0x141432)))
        // 불빛 번짐 + 땅 그림자
        context.fill(Path(CGRect(origin: .zero, size: designSize)), with: .radialGradient(
            Gradient(stops: [.init(color: rgb(0xffb35c).opacity(0.62), location: 0),
                             .init(color: rgb(0xe2702a).opacity(0.26), location: 0.35),
                             .init(color: rgb(0xe2702a).opacity(0), location: 1)]),
            center: CGPoint(x: 180, y: 600), startRadius: 0, endRadius: 300))
        context.fill(Path(ellipseIn: CGRect(x: 180 - 280, y: 700 - 110, width: 560, height: 220)),
                     with: .color(rgb(0x120c12).opacity(0.5)))

        // 장면(통나무·인물·불)은 불 아래 중심으로 1.1배.
        var scene = context
        scene.translateBy(x: 180, y: 652)
        scene.scaleBy(x: 1.1, y: 1.1)
        scene.translateBy(x: -180, y: -652)

        drawLog(&scene, 16, 640, 104); drawLog(&scene, 236, 640, 104)
        person(&scene, x: 26, y: 641, scale: 1.08, facingLeft: false, hair: .bun, blanket: true)
        person(&scene, x: 104, y: 652, scale: 0.78, facingLeft: false, hair: .short)
        person(&scene, x: 262, y: 641, scale: 1.05, facingLeft: true, hair: .long, mug: true, time: time)
        agent(&scene, x: 338, y: 641, scale: 1.05, facingLeft: true, time: time)
        drawLog(&scene, 92, 650, 56); drawLog(&scene, 212, 650, 56)
        fire(&scene, time: time)
    }

    // MARK: - 조각

    private static func drawLog(_ c: inout GraphicsContext, _ x: Double, _ y: Double, _ w: Double) {
        c.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: 10), cornerRadius: 5), with: .color(rgb(0x2b1a14)))
        c.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: 3), cornerRadius: 1.5), with: .color(rgb(0x6b3a22).opacity(0.55)))
        c.fill(circle(x + 4, y + 5, 3.6), with: .color(rgb(0x4a2c1c)))
    }

    private struct Palette { let base, leg, arm, hair: Color }

    /// 몸(다리·몸통·팔·머리·코·머리카락). 같은 몸을 불 쪽으로 살짝 민 따뜻한 복제본 위에 칠해 윤곽광을 만든다.
    private static func body(_ c: inout GraphicsContext, _ p: Palette, hair: Hair?, blanket: Color?) {
        c.fill(path(leg), with: .color(p.leg))
        c.fill(path(torso), with: .color(p.base))
        if let blanket { c.fill(path(Self.blanket), with: .color(blanket)) }
        c.stroke(path(arm), with: .color(p.arm), style: StrokeStyle(lineWidth: 8.5, lineCap: .round))
        c.fill(circle(head.x, head.y, head.r), with: .color(p.base))
        c.fill(circle(nose.x, nose.y, nose.r), with: .color(p.base))
        if let hair {
            c.fill(path(hair.path), with: .color(p.hair))
            if hair == .bun { c.fill(circle(29, -91, 5.5), with: .color(p.hair)) }
        }
    }

    private static func placed(_ c: GraphicsContext, x: Double, y: Double, scale: Double, facingLeft: Bool) -> GraphicsContext {
        var g = c
        g.translateBy(x: x, y: y)
        g.scaleBy(x: facingLeft ? -scale : scale, y: scale)
        return g
    }

    private static func person(_ c: inout GraphicsContext, x: Double, y: Double, scale: Double, facingLeft: Bool,
                               hair: Hair, blanket: Bool = false, mug: Bool = false, time: TimeInterval = 0) {
        var g = placed(c, x: x, y: y, scale: scale, facingLeft: facingLeft)
        let rimColor = rgb(0xf2a25a)
        var rim = g
        rim.translateBy(x: 1.9, y: -0.6)
        rim.opacity = 0.95
        body(&rim, Palette(base: rimColor, leg: rimColor, arm: rimColor, hair: rimColor), hair: hair, blanket: blanket ? rimColor : nil)
        body(&g, Palette(base: rgb(0x1c1520), leg: rgb(0x241922), arm: rgb(0x2c1e26), hair: rgb(0x120d14)),
             hair: hair, blanket: blanket ? rgb(0x5e2c26) : nil)
        if mug {
            g.fill(Path(roundedRect: CGRect(x: 58, y: -47, width: 9, height: 11), cornerRadius: 2), with: .color(rgb(0xe7b277)))
            g.stroke(path(mugHandle), with: .color(rgb(0xe7b277)), lineWidth: 1.8)
            var s = g
            s.translateBy(x: 0, y: -2 * sin(time * 1.3))
            s.opacity = 0.4 + 0.15 * sin(time * 2.1)
            s.stroke(path(steam), with: .color(rgb(0xffe3bd)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        }
    }

    private static func agent(_ c: inout GraphicsContext, x: Double, y: Double, scale: Double, facingLeft: Bool, time: TimeInterval) {
        var g = placed(c, x: x, y: y, scale: scale, facingLeft: facingLeft)
        let rimColor = rgb(0x8cc4ff)
        var rim = g
        rim.translateBy(x: 1.9, y: -0.6)
        rim.opacity = 0.9
        body(&rim, Palette(base: rimColor, leg: rimColor, arm: rimColor, hair: rimColor), hair: nil, blanket: nil)
        var base = g
        base.opacity = 0.9
        body(&base, Palette(base: rgb(0x1b2850), leg: rgb(0x1e2c57), arm: rgb(0x253563), hair: .clear), hair: nil, blanket: nil)
        // 빛나는 구체 머리(천천히 숨 쉬듯)
        let breathe = 1 + 0.06 * sin(time * 1.6)
        g.fill(circle(head.x, head.y, (head.r + 10) * breathe), with: .radialGradient(
            Gradient(stops: [.init(color: rgb(0xcfe6ff), location: 0),
                             .init(color: rgb(0x6aa8f5).opacity(0.55), location: 0.5),
                             .init(color: rgb(0x6aa8f5).opacity(0), location: 1)]),
            center: CGPoint(x: head.x, y: head.y), startRadius: 0, endRadius: (head.r + 10) * breathe))
        g.fill(circle(head.x, head.y, head.r), with: .color(rgb(0xe3f1ff)))
        g.fill(circle(head.x, head.y, head.r - 4), with: .color(.white.opacity(0.7)))
        for (i, (sx, sy, r, o)) in [(60.0, -100.0, 1.3, 0.7), (22, -104, 1, 0.5), (66, -76, 1, 0.45), (14, -70, 0.9, 0.4)].enumerated() {
            let twinkle = 0.6 + 0.4 * sin(time * 2 + Double(i) * 1.7)
            g.fill(circle(sx, sy, r), with: .color(rgb(0xa9d4ff).opacity(o * twinkle)))
        }
    }

    private static func fire(_ c: inout GraphicsContext, time: TimeInterval) {
        c.fill(Path(ellipseIn: CGRect(x: 180 - 38, y: 652 - 7, width: 76, height: 14)), with: .color(rgb(0x2a1a14)))
        c.stroke(path(sticks), with: .color(rgb(0x4a2c1c)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        // 불꽃: 바닥(180, 640)을 기준으로 세로로 살짝 늘었다 줄었다, 층마다 박자를 조금씩 어긋나게.
        for (i, (d, color)) in flames.enumerated() {
            var f = c
            let flicker = 1 + 0.045 * sin(time * 9 + Double(i)) + 0.02 * sin(time * 23 + Double(i) * 2)
            let sway = 0.8 * sin(time * 5 + Double(i) * 0.7)
            f.translateBy(x: 180 + sway, y: 640)
            f.scaleBy(x: 1, y: flicker)
            f.translateBy(x: -180, y: -640)
            f.fill(path(d), with: .color(color))
        }
        // 불티: 위로 오르며 사라진다.
        for i in 0..<6 {
            let speed = 0.22 + 0.05 * Double(i % 3)
            let progress = (time * speed + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
            let x = 180 + 22 * sin(Double(i) * 2.1 + progress * 3)
            let y = 560 - progress * 130
            c.fill(circle(x, y, 1.6 - progress), with: .color(rgb(0xffcf73).opacity(0.9 * (1 - progress))))
        }
    }

    // MARK: - 도우미

    /// path 문자열 → Path(짧아서 프레임마다 다시 해석해도 싸다 — 공유 캐시를 두지 않는다).
    static func path(_ d: String) -> Path {
        var p = Path()
        for command in SVGPathData.parse(d) ?? [] {
            switch command {
            case .move(let a): p.move(to: CGPoint(x: a.x, y: a.y))
            case .line(let a): p.addLine(to: CGPoint(x: a.x, y: a.y))
            case .cubic(let c1, let c2, let e):
                p.addCurve(to: CGPoint(x: e.x, y: e.y), control1: CGPoint(x: c1.x, y: c1.y), control2: CGPoint(x: c2.x, y: c2.y))
            case .quad(let q, let e): p.addQuadCurve(to: CGPoint(x: e.x, y: e.y), control: CGPoint(x: q.x, y: q.y))
            case .close: p.closeSubpath()
            }
        }
        return p
    }

    private static func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}
