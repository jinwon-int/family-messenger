// 에이전트 답장의 마크다운 → 블록(#405 P1). 순수 Swift(Linux `swift test`).
// 블록(제목·문단·목록·표·코드·인용·구분선)만 여기서 나누고, 굵게·기울임·`코드` 같은 줄 안 서식은
// 화면이 `AttributedString(markdown:, .inlineOnlyPreservingWhitespace)` 로 그린다.
// 웹 `rich-text.js` 와 같은 원칙: 받은 글은 신뢰하지 않는다 — 원격 이미지·링크 이동은 화면에서 끈다(텍스트로만 보임).
import Foundation

public enum AgentMarkdown {
    public enum Block: Equatable {
        case heading(level: Int, text: String)
        /// 줄바꿈은 그대로(채팅 글은 줄 단위로 쓴다).
        case paragraph(String)
        /// `level` = 들여쓰기 깊이(0부터). `marker` = 번호 목록이면 "1." 같은 원래 표시, 아니면 nil.
        case list([ListItem])
        case table(header: [String], rows: [[String]])
        case code(String)
        case quote(String)
        case rule
    }

    public struct ListItem: Equatable {
        public let level: Int
        public let marker: String?
        public let text: String
        public init(level: Int, marker: String?, text: String) { self.level = level; self.marker = marker; self.text = text }
    }

    /// 표가 아무리 길어도 화면이 감당할 만큼만(열 8 · 행 60). 넘치는 행은 버리고 끝에 "…" 행을 둔다.
    public static let maxColumns = 8
    public static let maxRows = 60

    public static func parse(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var quote: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushList() {
            if !list.isEmpty { blocks.append(.list(list)); list = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        func flushAll() { flushParagraph(); flushList(); flushQuote() }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 코드 울타리: 닫는 ``` 까지(없으면 끝까지) 그대로.
            if trimmed.hasPrefix("```") {
                flushAll()
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                blocks.append(.code(body.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty { flushAll(); i += 1; continue }

            // 표: 이 줄에 `|` 가 있고 다음 줄이 구분선(|---|:--:|)이면.
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushAll()
                let header = Array(cells(trimmed).prefix(maxColumns))
                var rows: [[String]] = []
                var truncated = false
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    if rows.count < maxRows { rows.append(normalize(cells(row), to: header.count)) } else { truncated = true }
                    i += 1
                }
                if truncated { rows.append(normalize(["…"], to: header.count)) }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if let level = headingLevel(trimmed) {
                flushAll()
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }
            if isRule(trimmed) { flushAll(); blocks.append(.rule); i += 1; continue }
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }
            if let item = listItem(line) {
                flushParagraph(); flushQuote()
                list.append(item)
                i += 1
                continue
            }
            // 목록 바로 뒤의 들여쓴 이어지는 줄은 앞 항목에 붙인다.
            if !list.isEmpty, line.first == " " || line.first == "\t" {
                let last = list.removeLast()
                list.append(ListItem(level: last.level, marker: last.marker, text: last.text + "\n" + trimmed))
                i += 1
                continue
            }
            flushList(); flushQuote()
            paragraph.append(line)
            i += 1
        }
        flushAll()
        return blocks
    }

    /// 줄 안 서식이 하나라도 있는가(화면이 AttributedString 변환을 건너뛸지 판단).
    public static func hasInlineMarkup(_ text: String) -> Bool {
        text.contains("**") || text.contains("`") || text.contains("__") || text.contains("*") || text.contains("~~") || text.contains("[")
    }

    static func cells(_ row: String) -> [String] {
        var s = Substring(row.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s = s.dropLast() }
        // `\|` 는 칸 안의 글자.
        let placeholder = "\u{0}"
        let protected = s.replacingOccurrences(of: "\\|", with: placeholder)
        return protected.components(separatedBy: "|").map {
            $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces)
        }
    }

    static func normalize(_ row: [String], to width: Int) -> [String] {
        guard width > 0 else { return row }
        if row.count >= width { return Array(row.prefix(width)) }
        return row + Array(repeating: "", count: width - row.count)
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let parts = cells(line)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            var p = Substring(part)
            if p.hasPrefix(":") { p = p.dropFirst() }
            if p.hasSuffix(":") { p = p.dropLast() }
            return p.count >= 3 && p.allSatisfy { $0 == "-" }
        }
    }

    static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        return rest.first == " " ? hashes : nil
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let c = compact.first, "-*_".contains(c) else { return false }
        return compact.allSatisfy { $0 == c }
    }

    static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        let level = min(indent / 2, 4)
        if let first = body.first, "-*•+".contains(first), body.dropFirst().first == " " {
            return ListItem(level: level, marker: nil, text: body.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
        if (1...3).contains(digits.count) {
            let after = body.dropFirst(digits.count)
            if let p = after.first, p == "." || p == ")", after.dropFirst().first == " " {
                return ListItem(level: level, marker: "\(digits)\(p)", text: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
