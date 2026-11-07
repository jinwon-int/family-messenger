// alert-refs-v1(archive/native-mls/ALERT-REFS-V1.md, 오너 요청 2026-11-07) — 플릿 알림의 `#번호` 를 눌러 원래 알림으로 이동.
// 판정은 세 앱 공통(공유 벡터 tests/fixtures/alert-refs-vectors.json). 유니코드 스칼라 단위로 훑는다(라벨 40 = 코드 포인트).
import Foundation

public enum AlertRefs {
    /// 플릿 알림 봇 actor(기기 `fleet-bot`). 링크는 이 봇의 글에만.
    public static let fleetActor = "fleet"
    /// 앱 안 이동용 링크 주소(`hande-alert://<번호>`) — 시스템으로 넘기지 않고 방 화면이 가로챈다.
    public static let scheme = "hande-alert"

    /// 참조 하나: 번호와 글 안 위치(유니코드 스칼라 offset, `#` 포함 [start, end)).
    public struct Ref: Equatable {
        public let id: String
        public let start: Int
        public let end: Int
    }

    public struct Parsed: Equatable {
        public let selfID: String?
        public let refs: [Ref]
    }

    static func isIDChar(_ c: Unicode.Scalar) -> Bool { (c >= "0" && c <= "9") || (c >= "a" && c <= "z") }
    static func isWord(_ c: Unicode.Scalar) -> Bool { (c >= "0" && c <= "9") || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_" }

    /// s[i] 에서 시작하는 번호(§1 경계 규칙)면 6자, 아니면 nil.
    static func id(at i: Int, in s: [Unicode.Scalar]) -> String? {
        guard i < s.count, s[i] == "#" else { return nil }
        if i > 0, isWord(s[i - 1]) || s[i - 1] == "#" { return nil }
        guard i + 7 <= s.count else { return nil }
        let body = s[(i + 1)..<(i + 7)]
        guard body.allSatisfy(isIDChar) else { return nil }
        if i + 7 < s.count, isWord(s[i + 7]) { return nil }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: body)
        return String(view)
    }

    /// `[라벨] ` 접두(라벨 1~40 스칼라, `]`·줄바꿈 없음)의 길이, 없으면 0.
    static func labelLength(_ s: [Unicode.Scalar]) -> Int {
        guard s.first == "[" else { return 0 }
        var i = 1
        while i < s.count, i <= 41, s[i] != "]", s[i] != "\n" { i += 1 }
        let label = i - 1
        guard (1...40).contains(label), i + 1 < s.count, s[i] == "]", s[i + 1] == " " else { return 0 }
        return i + 2
    }

    public static func parse(_ text: String) -> Parsed {
        let s = Array(text.unicodeScalars)
        guard !s.isEmpty else { return Parsed(selfID: nil, refs: []) }
        let at = labelLength(s)
        var selfID: String?
        if let own = id(at: at, in: s), at + 7 == s.count || s[at + 7] == " " || s[at + 7] == "\n" { selfID = own }
        var refs: [Ref] = []
        var i = 0
        while i < s.count {
            if selfID != nil, i == at { i += 7; continue }
            if let ref = id(at: i, in: s), ref != selfID {
                refs.append(Ref(id: ref, start: i, end: i + 7))
                i += 7
                continue
            }
            i += 1
        }
        return Parsed(selfID: selfID, refs: refs)
    }

    public static func url(for id: String) -> URL? { URL(string: "\(scheme)://\(id)") }

    /// `hande-alert://<번호>` → 번호(형식이 맞을 때만).
    public static func id(from url: URL) -> String? {
        guard url.scheme == scheme, let host = url.host, host.unicodeScalars.count == 6,
              host.unicodeScalars.allSatisfy(isIDChar) else { return nil }
        return host
    }

    /// 이동 대상 seq: records(seq 오름차순) 중 플릿 알림 봇 글로 자기 번호가 id 인 가장 최근 것. 누른 글(`from`)은 뺀다.
    public static func target(id: String, in records: [MessageRecord], from: Int64? = nil) -> Int64? {
        for record in records.reversed() where record.kind == .text && record.seq != from && record.senderActor == fleetActor {
            if parse(record.body).selfID == id { return record.seq }
        }
        return nil
    }
}
