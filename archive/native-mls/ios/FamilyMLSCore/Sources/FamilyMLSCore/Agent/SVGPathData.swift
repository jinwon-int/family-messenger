// 오프닝 일러스트(#414)·한데 UI 아이콘(디자인 2차-B)용 최소 SVG path data 파서 — 순수 Swift(Linux `swift test`).
// 시안(/root/hande-ui/make_opening_v5.py)·아이콘 정본(docs/design/icons/ui/*.svg)과 앱이 같은 path 문자열을 쓰게 해 그림이 어긋나지 않게 한다.
// 지원: M/m L/l H/h V/v C/c S/s Q/q A/a Z/z, 같은 명령의 매개변수 반복(암묵적 반복). T 는 쓰지 않는다.
// 호(A/a)는 SVG 구현 노트 F.6.5(끝점 → 중심 매개변수화)로 중심·각을 구한 뒤 90° 이하 조각마다 3차 베지어 하나로 바꿔 `.cubic` 으로 낸다 —
// 그리는 쪽(OpeningArt.path)은 호를 몰라도 된다. 반지름 0 은 직선, 시작점 = 끝점이면 조각을 내지 않는다(명세대로).
// 매끈한 3차(S/s)는 앞 3차의 둘째 제어점을 현재점에 대해 반사한 점을 첫 제어점으로(앞이 3차가 아니면 현재점) `.cubic` 으로 낸다(불지기 아이콘의 어깨).
// 플래그(large-arc·sweep)는 숫자 토큰으로 읽는다 — 「0 0 1」처럼 띄어 쓴 것만(「01」처럼 붙여 쓴 압축 표기는 지원하지 않는다).
import Foundation

public enum SVGPathData {
    public struct Point: Equatable {
        public let x: Double
        public let y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public enum Command: Equatable {
        case move(Point)
        case line(Point)
        case cubic(Point, Point, Point)   // control1, control2, end
        case quad(Point, Point)           // control, end
        case close
    }

    /// 모두 절대 좌표로 바꾼 명령 목록. 해석할 수 없는 글자를 만나면 nil(그림을 반쯤 그리지 않는다).
    public static func parse(_ data: String) -> [Command]? {
        var tokens: [Token] = []
        guard tokenize(data, into: &tokens) else { return nil }
        var out: [Command] = []
        var i = 0
        var current = Point(0, 0)
        var start = Point(0, 0)
        var command: Character?
        /// 바로 앞 명령이 3차(C/S)였을 때 그 둘째 제어점 — S 의 반사 기준. 다른 명령 뒤에는 nil.
        var lastCubicControl: Point?

        func number() -> Double? {
            guard i < tokens.count, case .number(let v) = tokens[i] else { return nil }
            i += 1
            return v
        }
        func point(relative: Bool) -> Point? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? Point(current.x + x, current.y + y) : Point(x, y)
        }

        while i < tokens.count {
            if case .command(let c) = tokens[i] {
                command = c
                i += 1
            } else if command == nil {
                return nil
            }
            guard let c = command else { return nil }
            let relative = c.isLowercase
            let previousCubicControl = lastCubicControl
            lastCubicControl = nil
            switch c.lowercased() {
            case "m":
                guard let p = point(relative: relative) else { return nil }
                out.append(.move(p)); current = p; start = p
                command = relative ? "l" : "L"   // M 뒤의 추가 쌍은 L
            case "l":
                guard let p = point(relative: relative) else { return nil }
                out.append(.line(p)); current = p
            case "h":
                guard let x = number() else { return nil }
                let p = Point(relative ? current.x + x : x, current.y)
                out.append(.line(p)); current = p
            case "v":
                guard let y = number() else { return nil }
                let p = Point(current.x, relative ? current.y + y : y)
                out.append(.line(p)); current = p
            case "c":
                guard let c1 = point(relative: relative), let c2 = point(relative: relative),
                      let end = point(relative: relative) else { return nil }
                // 상대 좌표의 세 점은 모두 명령 시작점(current) 기준 — point(relative:) 가 그렇게 더한다.
                out.append(.cubic(c1, c2, end)); current = end
                lastCubicControl = c2
            case "s":
                guard let c2 = point(relative: relative), let end = point(relative: relative) else { return nil }
                let c1 = previousCubicControl.map { Point(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
                out.append(.cubic(c1, c2, end)); current = end
                lastCubicControl = c2
            case "q":
                guard let control = point(relative: relative), let end = point(relative: relative) else { return nil }
                out.append(.quad(control, end)); current = end
            case "a":
                // rx ry x-axis-rotation large-arc-flag sweep-flag x y — 끝점만 상대/절대, 반지름·각은 늘 그대로.
                guard let rx = number(), let ry = number(), let rotation = number(),
                      let largeArc = number(), let sweep = number(),
                      let end = point(relative: relative) else { return nil }
                guard largeArc == 0 || largeArc == 1, sweep == 0 || sweep == 1 else { return nil }
                out += arc(from: current, to: end, rx: rx, ry: ry, rotationDegrees: rotation,
                           largeArc: largeArc == 1, sweep: sweep == 1)
                current = end
            case "z":
                out.append(.close); current = start
                command = nil
            default:
                return nil
            }
        }
        return out
    }

    /// 타원 호 하나 → 3차 베지어 조각들(SVG 구현 노트 F.6.5 + 조각당 ≤90°). 반지름이 0 이면 직선, 시작 = 끝이면 빈 목록.
    static func arc(from p1: Point, to p2: Point, rx rxIn: Double, ry ryIn: Double,
                    rotationDegrees: Double, largeArc: Bool, sweep: Bool) -> [Command] {
        if p1 == p2 { return [] }
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { return [.line(p2)] }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        // 1) 시작·끝점의 중간을 원점으로, 회전을 푼 좌표(x1', y1').
        let dx2 = (p1.x - p2.x) / 2, dy2 = (p1.y - p2.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // 2) 반지름이 너무 작으면 키운다(F.6.6.2).
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = lambda.squareRoot()
            rx *= s; ry *= s
        }

        // 3) 중심(cx', cy').
        let rx2 = rx * rx, ry2 = ry * ry
        let numerator = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
        let denominator = rx2 * y1p * y1p + ry2 * x1p * x1p
        var coefficient = denominator == 0 ? 0 : (max(0, numerator / denominator)).squareRoot()
        if largeArc == sweep { coefficient = -coefficient }
        let cxp = coefficient * (rx * y1p / ry)
        let cyp = coefficient * -(ry * x1p / rx)

        // 4) 중심을 원래 좌표로.
        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2

        // 5) 시작각 θ1 · 쓸어가는 각 Δθ(단위원 기준).
        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        // 6) 90° 이하 조각으로 나눠 조각마다 3차 베지어 하나(단위원 → 타원 변환).
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        func map(_ x: Double, _ y: Double) -> Point {
            Point(cx + rx * cosPhi * x - ry * sinPhi * y, cy + rx * sinPhi * x + ry * cosPhi * y)
        }
        var out: [Command] = []
        var theta = theta1
        for index in 0..<segments {
            let next = theta + step
            let c1 = map(cos(theta) - t * sin(theta), sin(theta) + t * cos(theta))
            let c2 = map(cos(next) + t * sin(next), sin(next) - t * cos(next))
            // 마지막 조각의 끝은 떠다니는 오차 없이 정확히 끝점.
            let end = index == segments - 1 ? p2 : map(cos(next), sin(next))
            out.append(.cubic(c1, c2, end))
            theta = next
        }
        return out
    }

    /// 두 벡터 사이의 부호 있는 각(F.6.5.4).
    private static func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let dot = ux * vx + uy * vy
        let length = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
        guard length > 0 else { return 0 }
        let value = acos(min(1, max(-1, dot / length)))
        return (ux * vy - uy * vx) < 0 ? -value : value
    }

    enum Token: Equatable {
        case command(Character)
        case number(Double)
    }

    static func tokenize(_ s: String, into tokens: inout [Token]) -> Bool {
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace || c == "," { i += 1; continue }
            if "MmLlHhVvCcSsQqAaZz".contains(c) { tokens.append(.command(c)); i += 1; continue }
            if c == "-" || c == "+" || c == "." || c.isNumber {
                var j = i
                var seenDot = false, seenExp = false
                if chars[j] == "-" || chars[j] == "+" { j += 1 }
                while j < chars.count {
                    let d = chars[j]
                    if d.isNumber { j += 1; continue }
                    if d == "." && !seenDot && !seenExp { seenDot = true; j += 1; continue }
                    if (d == "e" || d == "E") && !seenExp {
                        seenExp = true; j += 1
                        if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
                        continue
                    }
                    break
                }
                guard let v = Double(String(chars[i..<j])) else { return false }
                tokens.append(.number(v))
                i = j
                continue
            }
            return false
        }
        return true
    }
}
