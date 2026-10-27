// file-v2 분리 첨부 설명자(#499, 정본 archive/native-mls/FILE-V2.md) — 엄격 검증. 웹 `file-v2.js parseDescriptor`·안드로이드
// `FileV2.kt` 와 같은 규칙(순수 Swift, Linux `swift test` 에서도 돈다).
//
// 바깥 client_id 가 `file-v2-` 로 시작하는 메시지의 평문은 파일을 열 **키**가 든 설명자 JSON 이다. 그래서 RoomSyncEngine 은 이
// 메시지를 어떤 경우에도 `.text` 로 저장하지 않는다(그러면 화면·NSE 알림 본문·messages.db 에 키가 남는다): 설명자가 올바르면
// `.fileV2`(body = mime 표시 힌트, attachment = 검증한 설명자 바이트 — 이력에는 설명자만, §4-2), 아니면 `.undecryptable`.
// blob 받기·열기(GET → sha256 → AES-256-GCM)는 후속 PR.
import Foundation

public enum FileV2Format {
    public static let version = 2
    public static let clientIdPrefix = "file-v2-"
    public static let maxFileBytes = 50 * 1024 * 1024   // #499 오너 결정
    public static let maxDescriptorBytes = 4096
    public static let keyBytes = 32
    public static let nonceBytes = 12
    public static let maxDimension = 20000
    public static let aad = "hande-file-v2"
    public static let gcmTagBytes = 16

    /// 설명자. `key`·`nonce` 는 비밀 — `description` 에 넣지 않는다(로그 유출 방지).
    public struct Descriptor: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        public let blob: String
        public let size: Int
        public let key: Data
        public let nonce: Data
        public let mime: String?
        public let name: String?
        public let width: Int?
        public let height: Int?
        public var description: String { "FileV2Format.Descriptor(blob: \(blob.prefix(12))…, size: \(size))" }
        public var debugDescription: String { description }
    }

    /// 거부 이유는 고정된 짧은 코드뿐(보낸 쪽 값·키 이름을 담지 않는다 — 로그·undecryptable 사유로 그대로 써도 된다).
    public struct Rejected: Error, Equatable {
        public let reason: String
    }

    /// 바깥 client_id 가 `file-v2-` 로 시작하는가 — 이 메시지는 글로 열지 않는다(정규형이 아니어도).
    public static func isFileV2Message(clientId: String) -> Bool { clientId.hasPrefix(clientIdPrefix) }

    /// `^file-v2-[a-f0-9-]{36}$`(표시 힌트일 뿐 인증 정보가 아니다 — FILE-V2.md §1).
    public static func isClientId(_ clientId: String) -> Bool {
        guard clientId.hasPrefix(clientIdPrefix) else { return false }
        let tail = clientId.utf8.dropFirst(clientIdPrefix.utf8.count)
        return tail.count == 36 && tail.allSatisfy { (0x61...0x66).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }

    /// MLS 평문(UTF-8 바이트)을 설명자로 엄격 검증한다. 하나라도 어긋나면 `Rejected`.
    public static func parseDescriptor(_ plaintext: Data) throws -> Descriptor {
        guard plaintext.count <= maxDescriptorBytes else { throw Rejected(reason: "too large") }
        let text = String(decoding: plaintext, as: UTF8.self)
        guard Data(text.utf8) == plaintext else { throw Rejected(reason: "not utf-8") }   // 잘못된 바이트는 U+FFFD 로 바뀌어 달라진다
        let parsed: StrictJSON.Value
        var json = StrictJSON(text)
        do { parsed = try json.parseDocument() } catch { throw Rejected(reason: "not json") }
        guard case .object(let raw) = parsed else { throw Rejected(reason: "not an object") }
        let required = ["v", "blob", "size", "key", "nonce"]
        let allowed = Set(required + ["mime", "name", "w", "h"])
        for k in raw.keys where !allowed.contains(k) { throw Rejected(reason: "unknown key") }
        for k in required where raw[k] == nil { throw Rejected(reason: "missing \(k)") }
        guard integer(raw["v"], version, version) != nil else { throw Rejected(reason: "version") }
        guard case .string(let blob)? = raw["blob"], isBlobId(blob) else { throw Rejected(reason: "blob") }
        guard let size = integer(raw["size"], 1, maxFileBytes) else { throw Rejected(reason: "size") }
        guard case .string(let keyText)? = raw["key"], let key = base64urlDecode(keyText), key.count == keyBytes else {
            throw Rejected(reason: "key")
        }
        guard case .string(let nonceText)? = raw["nonce"], let nonce = base64urlDecode(nonceText), nonce.count == nonceBytes else {
            throw Rejected(reason: "nonce")
        }
        var mime: String?
        if let value = raw["mime"] {
            guard case .string(let m) = value, m.utf16.count <= 100, isMime(m) else { throw Rejected(reason: "mime") }
            mime = m
        }
        var name: String?
        if let value = raw["name"] {
            guard case .string(let n) = value, isValidName(n) else { throw Rejected(reason: "name") }
            name = n
        }
        var width: Int?, height: Int?
        if let value = raw["w"] {
            guard let w = integer(value, 1, maxDimension) else { throw Rejected(reason: "w") }
            width = w
        }
        if let value = raw["h"] {
            guard let h = integer(value, 1, maxDimension) else { throw Rejected(reason: "h") }
            height = h
        }
        return Descriptor(blob: blob, size: size, key: key, nonce: nonce, mime: mime, name: name, width: width, height: height)
    }

    /// base64url(RFC 4648 §5, 패딩 없음, **정규형** — 다시 인코딩하면 같은 문자열). 아니면 nil.
    public static func base64urlDecode(_ text: String) -> Data? {
        let alphabet = text.utf8.allSatisfy {
            (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D || $0 == 0x5F
        }
        guard alphabet, text.utf8.count % 4 != 1 else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: standard) else { return nil }
        return base64urlEncode(data) == text ? data : nil
    }

    public static func base64urlEncode(_ data: Data) -> String {
        var s = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    // MARK: 규칙

    /// JS `Number.isSafeInteger(x) && lo <= x && x <= hi` 와 같다(`2.0`·`2e0` 도 2). 숫자가 아니면 nil.
    private static func integer(_ value: StrictJSON.Value?, _ lo: Int, _ hi: Int) -> Int? {
        guard case .number(let d)? = value, d.isFinite, d == d.rounded(.towardZero), abs(d) <= 9_007_199_254_740_991 else { return nil }
        let n = Int(d)
        return (lo...hi).contains(n) ? n : nil
    }

    private static func isBlobId(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// `^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}$`
    private static func isMime(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        func token(_ t: Substring) -> Bool {
            let bytes = Array(t.utf8)
            guard let first = bytes.first, bytes.count <= 64, alnum(first) else { return false }
            return bytes.allSatisfy { alnum($0) || "!#$&^_.+-".utf8.contains($0) }
        }
        return token(parts[0]) && token(parts[1])
    }

    private static func alnum(_ b: UInt8) -> Bool { (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || (0x30...0x39).contains(b) }

    /// 1~255 코드 포인트(웹 `[...name].length`), 제어 문자(U+0000–001F, U+007F–009F) 없음.
    private static func isValidName(_ n: String) -> Bool {
        let scalars = n.unicodeScalars
        return !scalars.isEmpty && scalars.count <= 255 && !scalars.contains { $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) }
    }
}

/// RFC 8259 JSON 의 엄격한 부분 구현 — 설명자(≤ 4 KiB) 검증 전용. 웹 `JSON.parse` 가 받는 문서만 받는다(앞뒤 JSON 공백만 허용,
/// 따옴표 없는 키·작은따옴표·주석·끝 쉼표·NaN 거부). 웹보다 엄격한 점 — 모두 송신자(`encodeDescriptor`)가 만들지 않는 모양:
/// **같은 키 두 번 거부**(`JSON.parse` 는 뒤 값 — 클라이언트마다 다른 blob 을 보는 일을 막는다), 앞머리 **BOM 거부**,
/// 짝 없는 서로게이트 `\uD800` 거부(Swift 문자열이 담을 수 없다). 안드로이드 `StrictJson`(FileV2.kt)과 같은 판정.
struct StrictJSON {
    indirect enum Value: Equatable {
        case object([String: Value]), array([Value]), string(String), number(Double), bool(Bool), null
    }
    struct Malformed: Error {}

    private let s: [UInt16]
    private var i = 0
    private var depth = 0

    init(_ text: String) { s = Array(text.utf16) }

    mutating func parseDocument() throws -> Value {
        ws()
        let v = try value()
        ws()
        guard i == s.count else { throw Malformed() }
        return v
    }

    private mutating func ws() { while i < s.count, [0x20, 0x09, 0x0A, 0x0D].contains(s[i]) { i += 1 } }
    private func peek() throws -> UInt16 { guard i < s.count else { throw Malformed() }; return s[i] }

    private mutating func value() throws -> Value {
        switch try peek() {
        case 0x7B: return try nested { try $0.object() }
        case 0x5B: return try nested { try $0.array() }
        case 0x22: return .string(try string())
        case 0x74: try literal("true"); return .bool(true)
        case 0x66: try literal("false"); return .bool(false)
        case 0x6E: try literal("null"); return .null
        default: return .number(try number())
        }
    }

    private mutating func nested(_ body: (inout StrictJSON) throws -> Value) throws -> Value {
        depth += 1
        guard depth <= 32 else { throw Malformed() }
        let v = try body(&self)
        depth -= 1
        return v
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf16)
        guard i + w.count <= s.count, Array(s[i..<(i + w.count)]) == w else { throw Malformed() }
        i += w.count
    }

    private mutating func object() throws -> Value {
        i += 1   // {
        var out: [String: Value] = [:]
        ws()
        if try peek() == 0x7D { i += 1; return .object(out) }
        while true {
            ws()
            guard try peek() == 0x22 else { throw Malformed() }
            let k = try string()
            ws()
            guard try peek() == 0x3A else { throw Malformed() }
            i += 1
            ws()
            let v = try value()
            guard out[k] == nil else { throw Malformed() }   // 중복 키
            out[k] = v
            ws()
            switch try peek() {
            case 0x2C: i += 1
            case 0x7D: i += 1; return .object(out)
            default: throw Malformed()
            }
        }
    }

    private mutating func array() throws -> Value {
        i += 1   // [
        var out: [Value] = []
        ws()
        if try peek() == 0x5D { i += 1; return .array(out) }
        while true {
            ws()
            out.append(try value())
            ws()
            switch try peek() {
            case 0x2C: i += 1
            case 0x5D: i += 1; return .array(out)
            default: throw Malformed()
            }
        }
    }

    private mutating func string() throws -> String {
        i += 1   // "
        var units: [UInt16] = []
        while true {
            let c = try peek()
            i += 1
            switch c {
            case 0x22:
                // 짝 없는 서로게이트는 거부(String 으로 옮기면 U+FFFD 로 바뀌어 보낸 값과 달라진다).
                let text = String(decoding: units, as: UTF16.self)
                guard Array(text.utf16) == units else { throw Malformed() }
                return text
            case 0x5C:
                let e = try peek()
                i += 1
                switch e {
                case 0x22, 0x5C, 0x2F: units.append(e)
                case 0x62: units.append(0x08)
                case 0x66: units.append(0x0C)
                case 0x6E: units.append(0x0A)
                case 0x72: units.append(0x0D)
                case 0x74: units.append(0x09)
                case 0x75:
                    guard i + 4 <= s.count else { throw Malformed() }
                    var code: UInt16 = 0
                    for k in 0..<4 {
                        guard let d = Self.hexDigit(s[i + k]) else { throw Malformed() }
                        code = code &* 16 &+ d
                    }
                    i += 4
                    units.append(code)
                default: throw Malformed()
                }
            case 0..<0x20: throw Malformed()   // 이스케이프하지 않은 제어 문자
            default: units.append(c)
            }
        }
    }

    private static func hexDigit(_ c: UInt16) -> UInt16? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    private mutating func number() throws -> Double {
        let start = i
        func digit(_ at: Int) -> Bool { at < s.count && (0x30...0x39).contains(s[at]) }
        if i < s.count, s[i] == 0x2D { i += 1 }
        if i < s.count, s[i] == 0x30 { i += 1 }
        else if i < s.count, (0x31...0x39).contains(s[i]) { while digit(i) { i += 1 } }
        else { throw Malformed() }
        if i < s.count, s[i] == 0x2E {
            i += 1
            guard digit(i) else { throw Malformed() }
            while digit(i) { i += 1 }
        }
        if i < s.count, s[i] == 0x65 || s[i] == 0x45 {
            i += 1
            if i < s.count, s[i] == 0x2B || s[i] == 0x2D { i += 1 }
            guard digit(i) else { throw Malformed() }
            while digit(i) { i += 1 }
        }
        let text = String(decoding: s[start..<i], as: UTF16.self)
        guard let d = Double(text) else { throw Malformed() }
        return d
    }
}
