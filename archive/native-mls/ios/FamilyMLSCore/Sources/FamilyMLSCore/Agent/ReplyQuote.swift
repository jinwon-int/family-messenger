// 말풍선 답장(오너 요청 2026-11-09) — 화면 없이 테스트하는 순수 로직(Linux `swift test`).
// 메시지 형식(프로토콜)은 바꾸지 않는다. 답할 글을 본문 맨 앞 마크다운 인용 한 줄로 붙이고 빈 줄 뒤에 내 글을 쓴다:
//
//   > 엄마 #1234: 내일 몇 시에 와?
//
//   7시쯤!
//
// `#1234` 는 답한 글의 릴레이 seq(같은 방 안 번호, 2026-11-09 v2) — 앱은 인용 상자를 누르면 그 글로 가고, 봇은 그 번호로 원문 전체를
// 찾아 에이전트에 넘길 수 있다. 번호 없는 v1(`> 엄마: …`)도 그대로 읽는다. 요약은 200자까지(v1 60자) — 번호를 못 쓰는 쪽도 원문을 알아보게.
//
// 왜 이 모양인가: 에이전트(봇)는 마크다운 인용을 그대로 이해하고, 웹·안드로이드·구버전 앱은 글 그대로 보여도 읽힌다.
// 빈 줄을 두는 이유는 마크다운에서 `>` 바로 다음 줄이 인용에 이어 붙기 때문이다(내 글이 인용 안으로 들어가지 않게).
// 앱은 이 머리를 말풍선 안 인용 상자로 그리고, 목록 미리보기·잠금화면 알림·복사·공유에는 내 글만 쓴다.
// 승인 답장 판정(`AgentApproval.reply` · 봇 `parse_approval_reply`)은 본문 맨 앞만 보므로 `> `로 시작하는 답장은 승인 명령이 되지 않는다.
import Foundation

public enum ReplyQuote {
    /// 인용 한 줄에 넣는 원문 요약 최대 글자 수(Character 기준 — 한글·이모지도 한 글자).
    public static let snippetLimit = 200

    public struct Parsed: Equatable {
        /// 인용 머리(「엄마 #1234: 내일 몇 시에 와?」 — `> ` 뺀 것).
        public let quote: String
        /// 답 본문(내 글).
        public let text: String
        /// 답한 사람 이름(머리에 `이름: ` 이 있으면). nil = 이름 없음.
        public var name: String? = nil
        /// 답한 글의 릴레이 seq(v2 `#번호`). nil = 번호 없음(v1·이름만).
        public var seq: Int64? = nil
        /// 원문 요약(머리에서 이름·번호를 뺀 것).
        public var snippet: String = ""

        public init(quote: String, text: String, name: String? = nil, seq: Int64? = nil, snippet: String? = nil) {
            self.quote = quote
            self.text = text
            self.name = name
            self.seq = seq
            self.snippet = snippet ?? quote
        }
    }

    /// 인용 한 줄에 넣을 원문 요약: 원문이 답장이면 그 인용을 뺀 본문, 줄 앞 `>`·줄바꿈은 걷어 한 줄로, 길면 자르고 「…」.
    public static func snippet(of body: String) -> String {
        let base = parse(body)?.text ?? body
        let lines = base.split(whereSeparator: \.isNewline).map { line -> String in
            var s = line.trimmingCharacters(in: .whitespaces)
            while s.first == ">" { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return s
        }.filter { !$0.isEmpty }
        let flat = lines.joined(separator: " ")
        guard flat.count > snippetLimit else { return flat }
        return String(flat.prefix(snippetLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// 보낼 본문: `> 이름 #seq: 요약` + 빈 줄 + 내 글. 이름이 비면 `#seq: 요약`, 번호가 없으면(보내는 중인 글 등) `이름: 요약`.
    public static func compose(name: String, seq: Int64? = nil, original: String, reply: String) -> String {
        let s = snippet(of: original)
        let ref = seq.flatMap { $0 > 0 ? "#\($0)" : nil }
        let label = [name.isEmpty ? nil : name, ref].compactMap { $0 }.joined(separator: " ")
        let head = label.isEmpty ? s : "\(label): \(s)"
        return "> \(head)\n\n\(reply)"
    }

    /// 답장 글이면 (인용, 본문). 첫 줄 하나만 `> ` 인용이고 바로 빈 줄 뒤에 본문이 있어야 한다.
    /// 인용만 있는 글·여러 줄 인용·빈 줄 없는 글은 답장이 아니다(nil — 종전처럼 글 그대로).
    public static func parse(_ body: String) -> Parsed? {
        guard body.hasPrefix("> "), let gap = body.range(of: "\n\n") else { return nil }
        let head = body[body.index(body.startIndex, offsetBy: 2)..<gap.lowerBound]
        guard !head.contains(where: \.isNewline) else { return nil }
        let quote = head.trimmingCharacters(in: .whitespaces)
        let text = String(body[gap.upperBound...])
        guard !quote.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let (name, seq, snippet) = splitHead(quote)
        return Parsed(quote: quote, text: text, name: name, seq: seq, snippet: snippet)
    }

    /// 머리 → (이름, seq, 요약). 첫 `: ` 앞이 라벨 — `이름 #123` · `#123` · `이름`(v1). `: ` 가 없으면 전부 요약.
    static func splitHead(_ head: String) -> (String?, Int64?, String) {
        guard let colon = head.range(of: ": ") else { return (nil, nil, head) }
        let label = String(head[..<colon.lowerBound])
        let snippet = String(head[colon.upperBound...])
        if let hash = label.range(of: "#", options: .backwards),
           hash.lowerBound == label.startIndex || label[label.index(before: hash.lowerBound)] == " " {
            let digits = label[hash.upperBound...]
            if !digits.isEmpty, digits.count <= 18, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
               let seq = Int64(digits), seq > 0 {
                let name = label[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
                return (name.isEmpty ? nil : name, seq, snippet)
            }
        }
        return (label.isEmpty ? nil : label, nil, snippet)
    }

    /// 화면 밖(목록 미리보기·알림·복사·공유)에 쓸 글: 답장이면 내 글만, 아니면 그대로.
    public static func visibleText(_ body: String) -> String {
        parse(body)?.text ?? body
    }
}
