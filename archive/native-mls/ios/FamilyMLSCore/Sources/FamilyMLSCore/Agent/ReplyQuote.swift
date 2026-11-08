// 말풍선 답장(오너 요청 2026-11-09) — 화면 없이 테스트하는 순수 로직(Linux `swift test`).
// 메시지 형식(프로토콜)은 바꾸지 않는다. 답할 글을 본문 맨 앞 마크다운 인용 한 줄로 붙이고 빈 줄 뒤에 내 글을 쓴다:
//
//   > 엄마: 내일 몇 시에 와?
//
//   7시쯤!
//
// 왜 이 모양인가: 에이전트(봇)는 마크다운 인용을 그대로 이해하고, 웹·안드로이드·구버전 앱은 글 그대로 보여도 읽힌다.
// 빈 줄을 두는 이유는 마크다운에서 `>` 바로 다음 줄이 인용에 이어 붙기 때문이다(내 글이 인용 안으로 들어가지 않게).
// 앱은 이 머리를 말풍선 안 인용 상자로 그리고, 목록 미리보기·잠금화면 알림·복사·공유에는 내 글만 쓴다.
// 승인 답장 판정(`AgentApproval.reply` · 봇 `parse_approval_reply`)은 본문 맨 앞만 보므로 `> `로 시작하는 답장은 승인 명령이 되지 않는다.
import Foundation

public enum ReplyQuote {
    /// 인용 한 줄에 넣는 원문 요약 최대 글자 수(Character 기준 — 한글·이모지도 한 글자).
    public static let snippetLimit = 60

    public struct Parsed: Equatable {
        /// 인용 머리(「엄마: 내일 몇 시에 와?」 — `> ` 뺀 것).
        public let quote: String
        /// 답 본문(내 글).
        public let text: String
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

    /// 보낼 본문: `> 이름: 요약` + 빈 줄 + 내 글. 이름이 비면 요약만.
    public static func compose(name: String, original: String, reply: String) -> String {
        let s = snippet(of: original)
        let head = name.isEmpty ? s : "\(name): \(s)"
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
        return Parsed(quote: quote, text: text)
    }

    /// 화면 밖(목록 미리보기·알림·복사·공유)에 쓸 글: 답장이면 내 글만, 아니면 그대로.
    public static func visibleText(_ body: String) -> String {
        parse(body)?.text ?? body
    }
}
