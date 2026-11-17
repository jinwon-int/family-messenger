// #834: 에이전트 답 끝의 사용 스킬 줄(`📘 gh-pr-flow · wiki-record`) → 본문 + 칩 이름.
// 봇이 브리지 `result.skills`(ccc-node#2833)로 붙이는 줄이다(native-mls bot `skills_footer`).
// 규칙은 웹 `agent-markdown.js` `splitSkills` 와 같다: 빈 줄 바로 뒤의 **마지막 줄**이 `📘 ` + 이름 1~8개(` · ` 로 구분)이고
// 이름이 모두 식별자 모양(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$`)이며 앞에 본문이 있을 때만 뗀다. 아니면 글 그대로.
import Foundation

public enum AgentSkills {
    /// 한 답에 담기는 스킬 이름 수 상한(봇 `MAX_REPLY_SKILLS`, 웹 `MAX_SKILLS` 와 같다).
    public static let maxSkills = 8
    static let prefix = "📘 "
    static let separator = " · "

    /// 본문(스킬 줄을 뗀 글)과 칩 이름(첫 등장 순, 중복 없음). 스킬 줄이 없으면 `(text, [])`.
    public static func split(_ text: String) -> (body: String, skills: [String]) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard lines.count >= 3, let last = lines.last, last.hasPrefix(prefix),
              lines[lines.count - 2].trimmingCharacters(in: .whitespaces).isEmpty else { return (text, []) }
        let names = String(last.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces).components(separatedBy: separator)
        guard !names.isEmpty, names.count <= maxSkills, names.allSatisfy(isSkillName) else { return (text, []) }
        let body = lines.dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return (text, []) }
        var seen: [String] = []
        for name in names where !seen.contains(name) { seen.append(name) }
        return (body, seen)
    }

    /// 식별자 모양 스킬 이름 — 브리지·봇·웹과 같은 규칙.
    static func isSkillName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, scalars.count <= 64, first.isASCII, isAlnum(first) else { return false }
        return scalars.allSatisfy { $0.isASCII && (isAlnum($0) || ".-_:".unicodeScalars.contains($0)) }
    }

    private static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
    }
}
