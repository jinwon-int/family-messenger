// 서비스 봇(알림 전용) 말풍선의 링크 — 허용한 호스트의 https 주소만 누를 수 있게 한다(웹 web/hande/service-links.js 와 같은 규칙).
// 에이전트 카드는 링크를 지운다(Views/AgentViews.swift InlineMarkdown). 서비스 봇은 사람이 쓴 글을 옮기지 않고 고정 형식 알림만
// 보내므로, 그 말풍선에 한해 **https + 허용 호스트**만 링크로 바꾼다. http·다른 호스트·사용자 정보·포트가 붙은 주소는 글 그대로.
import Foundation

enum ServiceLinks {
    /// 링크로 바꿀 호스트(소문자, 정확히 일치). 인스타그램 새 글 알림(`insta` 봇)용.
    static let hosts: Set<String> = ["instagram.com", "www.instagram.com"]

    private static let candidate = try! NSRegularExpression(pattern: "https://[^\\s<>\"'`]+")
    /// 주소 끝에 붙은 문장부호 — 문장의 일부일 때가 많아 링크에서 뺀다.
    private static let trailing = Set<Character>(".,!?;:)]}'\"…")

    /// `https://…` 한 덩어리가 허용 링크면 그 URL, 아니면 nil.
    static func allowedURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased(), hosts.contains(host),
              let url = parts.url
        else { return nil }
        return url
    }

    /// 글 속 허용 링크의 위치(NSRange, UTF-16)와 URL. 앞에서부터, 겹치지 않게.
    static func links(in text: String) -> [(range: NSRange, url: URL)] {
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: [(range: NSRange, url: URL)] = []
        for match in candidate.matches(in: text, range: whole) {
            guard var range = Range(match.range, in: text) else { continue }
            while range.lowerBound < range.upperBound, trailing.contains(text[text.index(before: range.upperBound)]) {
                range = range.lowerBound..<text.index(before: range.upperBound)
            }
            guard range.lowerBound < range.upperBound, let url = allowedURL(String(text[range])) else { continue }
            found.append((NSRange(range, in: text), url))
        }
        return found
    }

    /// 말풍선 글: 허용 링크 구간에만 `.link`(누르면 시스템이 연다), 나머지는 글 그대로.
    static func attributed(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        for link in links(in: text) {
            guard let range = Range(link.range, in: value) else { continue }
            value[range].link = link.url
        }
        return value
    }
}
