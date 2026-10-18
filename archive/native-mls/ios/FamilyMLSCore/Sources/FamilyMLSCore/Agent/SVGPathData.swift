// 오프닝 일러스트(#414)용 최소 SVG path data 파서 — 순수 Swift(Linux `swift test`).
// 시안(/root/hande-ui/make_opening_v5.py)과 앱이 같은 path 문자열을 쓰게 해 그림이 어긋나지 않게 한다.
// 지원: M/m L/l H/h V/v C/c Q/q Z/z, 같은 명령의 매개변수 반복(암묵적 반복). 호(A)·S/T 는 쓰지 않는다.
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
            case "q":
                guard let control = point(relative: relative), let end = point(relative: relative) else { return nil }
                out.append(.quad(control, end)); current = end
            case "z":
                out.append(.close); current = start
                command = nil
            default:
                return nil
            }
        }
        return out
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
            if "MmLlHhVvCcQqZz".contains(c) { tokens.append(.command(c)); i += 1; continue }
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
