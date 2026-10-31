// agent-choices-v1(#620) — 에이전트 글 끝의 번호 선택지를 탭해서 고르는 카드의 판정(화면 없이 테스트하는 순수 로직).
// 정본: archive/native-mls/AGENT-CHOICES-V1.md · 공유 벡터 tests/fixtures/agent-choices-vectors.json(웹·안드로이드와 같은 답).
// 보내는 것은 손으로 치는 것과 같은 꼴의 글 `N. 라벨` 줄들(#624 — 손으로 친 `1, 3` 도 같은 답) 이다 — 봇·브리지·와이어 무변경(승인 카드 「승인 n」과 같은 결).
//
// 플랫폼 간 차이를 없애려고 정규식 대신 유니코드 스칼라를 직접 훑는다: 숫자는 ASCII `0-9` 만(전각 `１` 은 숫자가 아니다),
// 공백(`\s`)은 스페이스·탭·줄바꿈만. Linux Foundation 에서도 같은 결과(Regex 리터럴·NSRegularExpression 미사용).
import Foundation

public struct AgentChoices: Equatable {
    public struct Item: Equatable {
        public let number: Int
        public let label: String

        public init(number: Int, label: String) {
            self.number = number
            self.label = label
        }
    }

    /// 1부터 이어지는 항목(2~9개).
    public let items: [Item]
    /// 권장 번호(1..items.count) 또는 nil.
    public let recommended: Int?

    public init(items: [Item], recommended: Int?) {
        self.items = items
        self.recommended = recommended
    }

    /// 번호의 라벨(없으면 nil).
    public func label(of number: Int) -> String? { items.first { $0.number == number }?.label }

    /// 타임라인에서 계산하는 카드 상태(저장하지 않는다, 규격 §2).
    public enum State: Equatable {
        /// 그 글 뒤에 저장된 메시지가 없다 — 선택 카드(체크 + 보내기).
        case open
        /// 바로 다음 메시지가 내 글이고 「답 판정」으로 번호 목록 S(오름차순·중복 없음·비어 있지 않음, 모두 1..k)가 된다(#624)
        /// — 한 줄 「✓ N번 선택 — 라벨」 / 여럿이면 「✓ 1, 3번 선택 — 라벨1 · 라벨3」.
        case answered([Int])
        /// 그 밖 — 카드 없음(말풍선만).
        case closed
    }

    /// 선택지가 있는 에이전트 글 하나의 판정 결과.
    public struct Card: Equatable {
        public let choices: AgentChoices
        public let state: State

        public init(choices: AgentChoices, state: State) {
            self.choices = choices
            self.state = state
        }
    }

    // MARK: - 판정(규격 §1)

    /// 에이전트 글 본문 → 선택지, 아니면 nil.
    public static func parse(_ text: String) -> AgentChoices? {
        let lines = splitLines(text)

        // 블록 훑기(규격 §1-4). 후보 = 마지막으로 시작된 블록.
        var block: [Item] = []
        var started = false        // 블록이 시작된 적이 있다
        var open = false           // 아직 항목·이어지는 줄을 받는다
        var invalid = false        // 무효(뒤에 `1` 이 오면 다시 시작)
        var firstLine = 0          // 블록 첫 항목 줄 index
        var lastLine = 0           // 마지막 항목 줄 또는 이어지는 줄 index
        var inFence = false

        for (index, line) in lines.enumerated() {
            if isFenceLine(line) {
                inFence.toggle()
                open = false       // 펜스 줄 = 그 밖의 줄 → 블록을 닫는다
                continue
            }
            if !inFence, let item = itemLine(line) {
                let number = item.number
                let rest = item.rest
                if number == 1 {
                    block = [Item(number: 1, label: cleanLabel(rest))]
                    started = true
                    open = true
                    invalid = false
                    firstLine = index
                    lastLine = index
                } else if started, open, !invalid, let last = block.last, number == last.number + 1 {
                    block.append(Item(number: number, label: cleanLabel(rest)))
                    lastLine = index
                } else {
                    invalid = true
                    open = false
                }
                continue
            }
            if isBlank(line) { continue }
            if isIndented(line) {
                if started, open, !invalid { lastLine = index }
                continue
            }
            open = false
        }

        guard started, !invalid else { return nil }
        // 항목 수 2~9.
        guard (2...9).contains(block.count) else { return nil }

        // 블록 뒤의 비어 있지 않은 줄 ≤ 3.
        let trailing = lines[(lastLine + 1)...].filter { !isBlank($0) }
        guard trailing.count <= 3 else { return nil }

        // 단서: 첫 항목 바로 위의 비어 있지 않은 줄 · 블록 뒤 줄들 · 항목 라벨.
        var cueSources: [[Unicode.Scalar]] = []
        if firstLine > 0, let above = lines[..<firstLine].last(where: { !isBlank($0) }) {
            cueSources.append(above)
        }
        cueSources.append(contentsOf: trailing)
        cueSources.append(contentsOf: block.map { Array($0.label.unicodeScalars) })
        guard cueSources.contains(where: hasCue) else { return nil }

        return AgentChoices(items: block, recommended: recommendedNumber(lines: lines, items: block))
    }

    /// 사람의 답장 본문 → 고른 번호 목록(오름차순·중복 없음, 모두 1..count), 아니면 nil. 규격 §2 「답 판정」(#624):
    /// A. 번호 나열(`1` · `1, 3`)을 먼저, nil 이면 B. 줄 형식(카드가 보내는 `1. 라벨` 줄들 — `compose` 결과)을 본다.
    public static func reply(_ text: String, count: Int) -> [Int]? {
        replyNumberList(text, count: count) ?? replyLines(text, count: count)
    }

    /// B. 줄 형식: `\r\n` → `\n` 후 줄로 나누고 공백뿐인 줄(스페이스·탭·`\r`)은 버린다. 남은 **모든** 줄이 §1 항목 줄
    /// (`itemLine` — parse 와 같은 판정)이어야 하고 번호가 모두 1..count. 라벨 글은 비교하지 않는다.
    static func replyLines(_ text: String, count: Int) -> [Int]? {
        let lines = splitLines(text).filter { line in !line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" } }
        guard !lines.isEmpty else { return nil }
        var numbers: [Int] = []
        for line in lines {
            guard let item = itemLine(line) else { return nil }
            numbers.append(item.number)
        }
        guard numbers.allSatisfy({ $0 >= 1 && $0 <= count }) else { return nil }
        return Array(Set(numbers)).sorted()
    }

    /// A. 번호 나열: 정규식 대신 차례로 읽는다 — 번호(ASCII 숫자 1~2자, 뒤에 공백·탭 + `번` 이 있으면 소비) · 구분자(공백·탭, 그리고
    /// `,` `，` `、` `/` `+` `→` `->` 가운데 하나, 다시 공백·탭 — 한 글자 이상 소비, 뒤가 글의 끝이면 안 됨)를 번갈아.
    /// 예: `1` · `2번` · `1, 3` · `1 → 2 → 3` · `1번, 2번`. 유니코드 스칼라 단위(→ ， 、 번 은 각각 스칼라 하나).
    static func replyNumberList(_ text: String, count: Int) -> [Int]? {
        var s = Array(text.unicodeScalars)
        // 1. 양끝의 스페이스·탭·\r·\n 제거 → 끝 `.` 하나 제거 → 다시 오른쪽 공백 제거.
        while let first = s.first, isReplyTrim(first) { s.removeFirst() }
        while let last = s.last, isReplyTrim(last) { s.removeLast() }
        if s.last == "." {
            s.removeLast()
            while let last = s.last, isReplyTrim(last) { s.removeLast() }
        }
        guard !s.isEmpty else { return nil }

        var numbers: [Int] = []
        var i = 0
        while true {
            // 2. 번호: ASCII 숫자 1~2자(3자 이상 nil — 긴 숫자열도 넘치지 않게 앞 두 자리만 셈).
            var value = 0
            var digits = 0
            while i < s.count, let d = digitValue(s[i]) {
                if digits < 2 { value = value * 10 + d }
                digits += 1
                i += 1
            }
            guard digits >= 1, digits <= 2 else { return nil }
            numbers.append(value)
            // (스페이스·탭 0개 이상 +) `번` 이 있으면 거기까지 소비 — 없으면 공백은 구분자 몫으로 남긴다.
            var j = i
            while j < s.count, isSpaceOrTab(s[j]) { j += 1 }
            if j < s.count, s[j] == "번" { i = j + 1 }
            // 3. 글의 끝이면 끝.
            if i == s.count { break }
            // 구분자: 공백·탭 → (선택) 구분 기호 하나 → 공백·탭. 한 글자도 못 먹었거나 뒤가 끝이면 nil.
            let start = i
            while i < s.count, isSpaceOrTab(s[i]) { i += 1 }
            if i < s.count {
                let c = s[i]
                if c == "," || c == "，" || c == "、" || c == "/" || c == "+" || c == "→" {
                    i += 1
                } else if c == "-", i + 1 < s.count, s[i + 1] == ">" {
                    i += 2
                }
            }
            while i < s.count, isSpaceOrTab(s[i]) { i += 1 }
            guard i > start, i < s.count else { return nil }
        }
        // 4. 모두 1..count, 오름차순·중복 제거.
        guard numbers.allSatisfy({ $0 >= 1 && $0 <= count }) else { return nil }
        return Array(Set(numbers)).sorted()
    }

    /// 보낼 글(규격 §2 「보낼 글」): 오름차순·중복 제거 후 줄마다 `N. 라벨` 을 `\n` 으로 잇는다 — 번호보다 내용이 중요하다(오너).
    /// `labels[N - 1]` = N번의 정리된 라벨(§1.6, `items.map(\.label)`). 라벨이 비었거나 없으면 `N. (내용 없음)`.
    /// 이 글은 답 판정 B 로 다시 같은 번호 집합이 된다(왕복).
    public static func compose(_ numbers: [Int], labels: [String]) -> String {
        Array(Set(numbers)).sorted().map { number -> String in
            let label = (number >= 1 && number <= labels.count) ? labels[number - 1] : ""
            let shown = label.trimmingCharacters(in: .whitespaces).isEmpty ? emptyLabel : label
            return "\(number). \(shown)"
        }.joined(separator: "\n")
    }

    /// 이 선택지의 라벨로 `compose`(카드 「보내기」가 보내는 글).
    public func composeReply(_ numbers: [Int]) -> String {
        AgentChoices.compose(numbers, labels: items.map(\.label))
    }

    /// 라벨이 빈 항목을 보낼 때(예: `1. **`).
    public static let emptyLabel = "(내용 없음)"

    /// 답 판정의 양끝 공백 = 스페이스·탭·\r·\n.
    static func isReplyTrim(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\t" || s == "\r" || s == "\n" }

    // MARK: - 상태(규격 §2)

    /// 선택지가 있는 에이전트 글 seq → 카드(선택지 + 상태). `records` 는 **저장된** 메시지만(seq 오름차순 — 보내는 중인 글 제외).
    /// 볼 메시지 = 글·첨부(시스템 줄·복호화 실패 제외). 「내 것」= `MessageRecord.isMine`(같은 사람의 다른 기기 포함 — 기존 규칙).
    public static func cards(_ records: [MessageRecord], roster: AgentRoster, myDevice: DeviceID) -> [Int64: Card] {
        let visible = records.filter { $0.kind == .text || $0.kind.isFile }
        var result: [Int64: Card] = [:]
        for (index, record) in visible.enumerated() {
            guard record.kind == .text, roster.isAgent(record), !record.isMine(device: myDevice),
                  let choices = parse(record.body) else { continue }
            let state: State
            if index + 1 >= visible.count {
                state = .open
            } else {
                let next = visible[index + 1]
                if next.kind == .text, next.isMine(device: myDevice),
                   let numbers = reply(next.body, count: choices.items.count) {
                    state = .answered(numbers)
                } else {
                    state = .closed
                }
            }
            result[record.seq] = Card(choices: choices, state: state)
        }
        return result
    }

    /// 선택지 글 seq → 상태(`cards` 의 상태만).
    public static func states(_ records: [MessageRecord], roster: AgentRoster, myDevice: DeviceID) -> [Int64: State] {
        cards(records, roster: roster, myDevice: myDevice).mapValues(\.state)
    }

    // MARK: - 줄 단위 도우미

    /// `\r\n` → `\n` 후 `\n` 으로 나눈다(스칼라 단위 — Swift 는 `\r\n` 을 한 글자로 본다).
    static func splitLines(_ text: String) -> [[Unicode.Scalar]] {
        var lines: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" {
                i += 1
                continue
            }
            if s == "\n" {
                lines.append(current)
                current = []
            } else {
                current.append(s)
            }
            i += 1
        }
        lines.append(current)
        return lines
    }

    static func isSpaceOrTab(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\t" }

    /// 규격의 공백(`\s`) = 스페이스·탭·줄바꿈.
    static func isSpaceOrNewline(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\t" || s == "\n" }

    static func digitValue(_ s: Unicode.Scalar) -> Int? {
        guard s.value >= 0x30, s.value <= 0x39 else { return nil }
        return Int(s.value - 0x30)
    }

    /// 공백뿐인 줄(빈 줄 포함).
    static func isBlank(_ line: [Unicode.Scalar]) -> Bool { line.allSatisfy(isSpaceOrNewline) }

    /// 들여쓴 줄: 공백 2칸 이상 또는 탭으로 시작.
    static func isIndented(_ line: [Unicode.Scalar]) -> Bool {
        if line.first == "\t" { return true }
        return line.count >= 2 && line[0] == " " && line[1] == " "
    }

    /// 왼쪽 공백을 뺀 줄이 ``` 로 시작한다.
    static func isFenceLine(_ line: [Unicode.Scalar]) -> Bool {
        let rest = line.drop(while: isSpaceOrTab)
        return rest.count >= 3 && rest.prefix(3).allSatisfy { $0 == "`" }
    }

    /// 항목 줄 `^ {0,3}([0-9]{1,2})[.)][ \t]+(\S.*)$` → (번호, 마커 뒤 글).
    static func itemLine(_ line: [Unicode.Scalar]) -> (number: Int, rest: [Unicode.Scalar])? {
        var i = 0
        while i < line.count, line[i] == " " { i += 1 }
        guard i <= 3 else { return nil }
        var value = 0
        var digits = 0
        while i < line.count, let d = digitValue(line[i]) {
            if digits < 2 { value = value * 10 + d }   // 3자리 이상은 어차피 항목이 아니다(긴 숫자열 넘침 방지)
            digits += 1
            i += 1
        }
        guard digits >= 1, digits <= 2 else { return nil }
        guard i < line.count, line[i] == "." || line[i] == ")" else { return nil }
        i += 1
        var gap = 0
        while i < line.count, isSpaceOrTab(line[i]) { i += 1; gap += 1 }
        guard gap >= 1, i < line.count else { return nil }   // 그 다음 글자는 공백이 아니다(\S)
        return (number: value, rest: Array(line[i...]))
    }

    /// 라벨: `**`·`__`·`` ` `` 를 지우고(왼쪽부터 한 번 훑기), 연속 공백 → 한 칸, 양끝 공백 제거.
    static func cleanLabel(_ raw: [Unicode.Scalar]) -> String {
        var stripped: [Unicode.Scalar] = []
        var i = 0
        while i < raw.count {
            let s = raw[i]
            if i + 1 < raw.count, (s == "*" && raw[i + 1] == "*") || (s == "_" && raw[i + 1] == "_") {
                i += 2
                continue
            }
            if s == "`" {
                i += 1
                continue
            }
            stripped.append(s)
            i += 1
        }
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for s in stripped {
            if isSpaceOrNewline(s) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(s)
            }
        }
        return String(out)
    }

    // MARK: - 단서 · 권장

    static let cueWords: [String] = [
        "?", "？", "권장", "선택", "골라", "고르", "답해", "원하시", "할까요", "하시겠", "정해", "다음 액션", "다음 단계", "옵션",
        "choose", "option", "recommend",
    ]
    static let cues: [[Unicode.Scalar]] = cueWords.map { Array($0.unicodeScalars) }

    /// 단서 문자열이 들어 있는가(영문은 대소문자 무시 — 줄을 소문자로 바꿔 비교).
    static func hasCue(_ line: [Unicode.Scalar]) -> Bool {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: line)
        let lowered = Array(String(view).lowercased().unicodeScalars)
        return cues.contains { scalarsContain(lowered, $0) }
    }

    static func scalarsContain(_ hay: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard hay.count >= needle.count else { return false }
        for start in 0...(hay.count - needle.count) {
            var match = true
            for k in 0..<needle.count where hay[start + k] != needle[k] {
                match = false
                break
            }
            if match { return true }
        }
        return false
    }

    /// 권장 번호: ① 메시지 전체(펜스 포함)의 `권장\s*[:：]?\s*([0-9]{1,2})\s*번` 첫 일치가 1..k → 그 번호,
    /// ② 아니면 라벨에 `권장` 이 든 첫 항목, ③ 아니면 nil.
    static func recommendedNumber(lines: [[Unicode.Scalar]], items: [Item]) -> Int? {
        var all: [Unicode.Scalar] = []
        for (index, line) in lines.enumerated() {
            if index > 0 { all.append("\n") }
            all.append(contentsOf: line)
        }
        // 첫 일치만 본다 — 그 번호가 범위 밖이면 라벨 규칙으로(벡터 「권장 N번 out of range falls back to label」).
        if let first = firstRecommendedMention(all), first >= 1, first <= items.count { return first }
        let mark = Array("권장".unicodeScalars)
        return items.first { scalarsContain(Array($0.label.unicodeScalars), mark) }?.number
    }

    /// `권장\s*[:：]?\s*([0-9]{1,2})\s*번` 의 첫(가장 왼쪽) 일치의 숫자.
    static func firstRecommendedMention(_ s: [Unicode.Scalar]) -> Int? {
        guard s.count >= 2 else { return nil }
        for start in 0..<(s.count - 1) where s[start] == "권" && s[start + 1] == "장" {
            var i = start + 2
            while i < s.count, isSpaceOrNewline(s[i]) { i += 1 }
            if i < s.count, s[i] == ":" || s[i] == "：" { i += 1 }
            while i < s.count, isSpaceOrNewline(s[i]) { i += 1 }
            var value = 0
            var digits = 0
            while i < s.count, let d = digitValue(s[i]) {
                if digits < 2 { value = value * 10 + d }   // 넘침 방지 — 3자리 이상은 일치가 아니다
                digits += 1
                i += 1
            }
            guard digits >= 1, digits <= 2 else { continue }
            while i < s.count, isSpaceOrNewline(s[i]) { i += 1 }
            if i < s.count, s[i] == "번" { return value }
        }
        return nil
    }
}
