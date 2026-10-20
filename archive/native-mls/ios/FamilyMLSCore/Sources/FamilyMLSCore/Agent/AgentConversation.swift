// 에이전트 대화 판정(#405 P1) — 화면 없이 테스트하는 순수 로직. 기준은 화면이 받은 타임라인(seq 오름차순)이다.
//   · AgentRoster: 누가 에이전트인가 — 빌드 설정 `FC_AGENT_ACTORS`(웹 `participants.js` 와 같은 원칙: 명시 목록이 정본, ID 모양으로 추측하지 않는다).
//   · AgentApproval: 봇의 `⚠️ 승인 필요 #n` 요청이 아직 열려 있는가 — 버튼은 「승인 n」/「거절 n」 글을 대신 보낼 뿐(봇·서버 무변경).
//   · LastSent: 대화창 위 "내 마지막 말" 바(웹 `last-sent.js`).
//   · AgentThinking: 에이전트가 답을 만드는 중으로 보이는가(입력 중 신호가 프로토콜에 없어 앱이 추정).
import Foundation

public struct AgentRoster: Equatable {
    public let actors: Set<String>

    public init(actors: Set<String>) { self.actors = actors }

    /// `FC_AGENT_ACTORS` 값(쉼표 구분, 공백·빈 항목 무시).
    public init(setting: String?) {
        actors = Set((setting ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public func isAgent(_ record: MessageRecord) -> Bool { actors.contains(record.senderActor) }

    /// 에이전트 기기 → 보여 줄 이름. `bot-gongmyoung` → names["gongmyoung"] ?? "gongmyoung".
    /// 사람 기기는 actor 그대로(`owner-iphone-27a879` → names["owner"] ?? "owner").
    public static func displayName(device: DeviceID, names: [String: String]) -> String {
        let parts = device.split(separator: "-", maxSplits: 1).map(String.init)
        let actor = parts.first ?? device
        if parts.count == 2, actor == "bot" || actor.hasPrefix("bot") {
            let node = parts[1]
            return names[node] ?? node
        }
        return names[actor] ?? actor
    }
}

public enum AgentApproval {
    public struct Request: Equatable {
        public let number: Int
        /// 첫 줄의 `: ` 뒤(무엇을 허락하는지). 없으면 빈 문자열.
        public let summary: String
    }

    public enum State: Equatable {
        /// 아직 답이 없다 — 허락/거절 버튼을 보인다.
        case open
        /// 내가 「승인 n」/「거절 n」을 보냈고 봇의 처리 글을 기다린다.
        case answered(allowed: Bool)
        case allowed
        case denied
        /// 같은 번호의 새 요청이 왔거나, 그 turn 이 끝났다(봇 재시작·불확실 안내·다음 답) — 버튼 없음.
        case closed
    }

    /// `⚠️ 승인 필요 #n: <요약>\n답장: 「승인 n」 또는 「거절 n」 (owner 만)` (native-mls-bot responder.rs).
    public static func request(in body: String) -> Request? {
        guard let range = body.range(of: "승인 필요 #") else { return nil }
        let rest = body[range.upperBound...]
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard let n = Int(digits), !digits.isEmpty else { return nil }
        var after = rest.dropFirst(digits.count)
        if after.hasPrefix(":") { after = after.dropFirst() }
        let firstLine = after.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return Request(number: n, summary: firstLine.trimmingCharacters(in: .whitespaces))
    }

    /// `승인 #n: 허용했습니다.` / `승인 #n: 거절했습니다.` (native-mls-bot session.rs `agent_text`).
    public static func resolution(in body: String) -> (number: Int, allowed: Bool)? {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("승인 #") else { return nil }
        let rest = t.dropFirst("승인 #".count)
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard let n = Int(digits), !digits.isEmpty else { return nil }
        if rest.contains("허용") { return (n, true) }
        if rest.contains("거절") { return (n, false) }
        return nil
    }

    /// 사람이 보낸 답장 `승인 n` / `거절 n`(`#` 허용, approve/deny 도) — 봇 `parse_approval_reply` 와 같은 모양.
    public static func reply(in body: String) -> (number: Int, allowed: Bool)? {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let words: [(String, Bool)] = [("승인", true), ("거절", false), ("approve", true), ("deny", false)]
        for (word, allowed) in words where t.lowercased().hasPrefix(word) {
            var rest = t.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("#") { rest = String(rest.dropFirst()) }
            if let n = Int(rest), n > 0 { return (n, allowed) }
        }
        return nil
    }

    /// 봇의 "끝까지 확인하지 못했습니다" 안내 — 그 turn 의 열린 요청은 닫힌다.
    static func isUncertainNotice(_ body: String) -> Bool { body.contains("끝까지 확인하지 못했습니다") }

    /// 요청 메시지 seq → 상태.
    public static func states(_ records: [MessageRecord], roster: AgentRoster) -> [Int64: State] {
        var result: [Int64: State] = [:]
        var pending: [Int: Int64] = [:]  // 번호 → 요청 seq
        for record in records where record.kind == .text {
            if roster.isAgent(record) {
                if let req = request(in: record.body) {
                    if let old = pending[req.number] { result[old] = .closed }
                    pending[req.number] = record.seq
                    result[record.seq] = .open
                } else if let res = resolution(in: record.body) {
                    if let seq = pending.removeValue(forKey: res.number) {
                        result[seq] = res.allowed ? .allowed : .denied
                    }
                } else {
                    // 일반 답장·불확실 안내 = 그 turn 이 끝났다. 열린 요청은 더는 답을 받지 않는다.
                    for seq in pending.values { result[seq] = .closed }
                    pending.removeAll()
                }
            } else if let reply = reply(in: record.body), let seq = pending[reply.number], result[seq] == .open {
                result[seq] = .answered(allowed: reply.allowed)
            }
        }
        return result
    }
}

public struct LastSent: Equatable {
    public let record: MessageRecord
    /// 그 뒤에 다른 사람이 보낸 메시지 수(글·첨부).
    public let repliesAfter: Int

    /// 내 마지막 글/첨부 — 같은 사람의 다른 기기에서 보낸 것도 내 글(`MessageRecord.isMine`). 승인 답장(「승인 1」)은
    /// "내가 한 말"로 치지 않는다 — 에이전트에게 무엇을 시켰는지가 이 바의 목적.
    public static func find(_ records: [MessageRecord], myDevice: DeviceID) -> LastSent? {
        guard !myDevice.isEmpty else { return nil }
        guard let index = records.lastIndex(where: { r in
            r.isMine(device: myDevice) && (r.kind == .attachment || (r.kind == .text && AgentApproval.reply(in: r.body) == nil))
        }) else { return nil }
        let replies = records[(index + 1)...].filter { !$0.isMine(device: myDevice) && ($0.kind == .text || $0.kind == .attachment) }.count
        return LastSent(record: records[index], repliesAfter: replies)
    }
}

public enum AgentThinking {
    /// 봇 워치독(1200초)과 같은 상한 — 이보다 오래 답이 없으면 "생각 중"을 내린다(봇이 불확실 안내를 따로 보낸다).
    public static let window: TimeInterval = 20 * 60

    /// 생각 중으로 보이는 에이전트 기기, 아니면 nil.
    /// 조건: 이 방에서 에이전트가 말한 적이 있고 · 마지막 메시지가 내 글(같은 사람의 다른 기기 포함 · 승인 답장 포함 · 첨부 제외 — 봇은 첨부에 답하지 않는다)이며
    /// · 그 글이 `window` 안이다. 에이전트의 마지막 글이 열린 승인 요청이면 "내 차례"라 nil.
    public static func agent(_ records: [MessageRecord], roster: AgentRoster, myDevice: DeviceID, now: Date) -> DeviceID? {
        guard !myDevice.isEmpty else { return nil }
        let visible = records.filter { $0.kind == .text || $0.kind == .attachment }
        guard let last = visible.last, last.isMine(device: myDevice), last.kind == .text else { return nil }
        guard now.timeIntervalSince(last.receivedAt) < window else { return nil }
        guard let agent = visible.last(where: { roster.isAgent($0) }) else { return nil }
        return agent.senderDevice
    }
}
