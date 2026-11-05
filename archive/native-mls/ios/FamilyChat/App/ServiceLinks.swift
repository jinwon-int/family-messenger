// 말풍선의 링크 — 허용한 호스트의 https 주소만 누를 수 있게 한다(웹 web/hande/service-links.js · Android core/TextLinks.kt 와 같은 규칙).
// 서비스 봇(알림 전용)은 사람이 쓴 글을 옮기지 않고 고정 형식 알림만 보내므로 `hosts`(인스타그램 + x.com)를, 사람 말풍선은
// `xHosts`(x.com·twitter.com, #683)만 링크로 바꾼다. 에이전트 카드는 링크를 지운다(Views/AgentViews.swift InlineMarkdown).
// http·다른 호스트·사용자 정보·포트가 붙은 주소는 글 그대로.
import Foundation

enum ServiceLinks {
    /// 사람·서비스 봇 말풍선에서 링크로 바꿀 x.com 계열 호스트(소문자, 정확히 일치, #683).
    static let xHosts: Set<String> = ["x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"]
    /// 서비스 봇 말풍선에서 링크로 바꿀 호스트. 인스타그램 새 글 알림(`insta` 봇)용 + x.com 계열.
    static let hosts: Set<String> = Set(["instagram.com", "www.instagram.com"]).union(xHosts)

    private static let candidate = try! NSRegularExpression(pattern: "https://[^\\s<>\"'`]+")
    /// 주소 끝에 붙은 문장부호 — 문장의 일부일 때가 많아 링크에서 뺀다.
    private static let trailing = Set<Character>(".,!?;:)]}'\"…")

    /// `https://…` 한 덩어리가 허용 링크면 그 URL, 아니면 nil.
    static func allowedURL(_ text: String, hosts: Set<String> = ServiceLinks.hosts) -> URL? {
        guard let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased(), hosts.contains(host),
              let url = parts.url
        else { return nil }
        return url
    }

    /// 글 속 허용 링크의 위치(NSRange, UTF-16)와 URL. 앞에서부터, 겹치지 않게.
    static func links(in text: String, hosts: Set<String> = ServiceLinks.hosts) -> [(range: NSRange, url: URL)] {
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: [(range: NSRange, url: URL)] = []
        for match in candidate.matches(in: text, range: whole) {
            guard var range = Range(match.range, in: text) else { continue }
            while range.lowerBound < range.upperBound, trailing.contains(text[text.index(before: range.upperBound)]) {
                range = range.lowerBound..<text.index(before: range.upperBound)
            }
            guard range.lowerBound < range.upperBound, let url = allowedURL(String(text[range]), hosts: hosts) else { continue }
            found.append((NSRange(range, in: text), url))
        }
        return found
    }

    // MARK: 미리보기 카드 대상 (#683 2단계, 계약 v1 클라이언트 절)

    /// 사람·서비스 봇 말풍선 글 속 x.com 계열 링크(`xHosts`, 위 링크 규칙) 중 상태 글 주소인 **첫 번째**. 없으면 nil(카드 없음).
    static func previewTarget(in text: String) -> URL? {
        links(in: text, hosts: xHosts).first { isStatusURL($0.url) }?.url
    }

    /// 릴레이 입력 규칙과 같은 경로: `/{handle}/status/{id}` 또는 `/i/web/status/{id}` — handle `[A-Za-z0-9_]{1,15}`, id 숫자 1–25자리.
    /// 그 뒤 경로(`/photo/1` 등)·쿼리는 있어도 된다(릴레이가 버린다). 호스트·스킴은 `links(in:hosts:)` 가 이미 걸렀다.
    static func isStatusURL(_ url: URL) -> Bool {
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath, path.hasPrefix("/") else { return false }
        let s = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if s.count >= 4, s[0] == "i", s[1] == "web", s[2] == "status" { return isStatusID(s[3]) }
        return s.count >= 3 && isHandle(s[0]) && s[1] == "status" && isStatusID(s[2])
    }

    private static func isHandle(_ s: String) -> Bool {
        guard (1...15).contains(s.utf8.count) else { return false }
        return s.utf8.allSatisfy { (b: UInt8) -> Bool in
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "_"):
                return true
            default:
                return false
            }
        }
    }

    private static func isStatusID(_ s: String) -> Bool {
        guard (1...25).contains(s.utf8.count) else { return false }
        return s.utf8.allSatisfy { (b: UInt8) -> Bool in UInt8(ascii: "0") <= b && b <= UInt8(ascii: "9") }
    }

    /// 말풍선 글: 허용 링크 구간에만 `.link`(누르면 시스템이 연다), 나머지는 글 그대로.
    static func attributed(_ text: String, hosts: Set<String> = ServiceLinks.hosts) -> AttributedString {
        var value = AttributedString(text)
        for link in links(in: text, hosts: hosts) {
            guard let range = Range(link.range, in: value) else { continue }
            value[range].link = link.url
        }
        return value
    }
}
