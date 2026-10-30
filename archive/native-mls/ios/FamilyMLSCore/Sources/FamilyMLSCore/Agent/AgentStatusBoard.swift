// status-v1(#560, STATUS-V1.md §3) — 방 하나의 에이전트 작업 상태 임시 말풍선(웹 `status-v1.js` 와 같은 판정).
//
// 보낸이마다 말풍선 하나: 새 status 가 오면 본문만 바뀌고(더 앞선 seq 는 무시), 같은 보낸이의 다음 일반 메시지(글·첨부·해독 불가 —
// 그 status 보다 큰 seq)가 오면 사라지며, 마지막 갱신 뒤 `ttl`(5분) 동안 아무것도 없으면 사라진다(답 없이 끝난 턴의 안전망).
// MessageStore 밖에만 있으므로 안 읽음·「내 마지막 말」·복사·알림에는 처음부터 들어가지 않는다. 방 목록 미리보기에는
// 보이는 status 가 있는 동안 가장 최근 줄을 따로 보인다(`listLine` — 오너 결정 2026-10-30: 목록에서 일하는 중인지 알 수 있게).
import Foundation

public struct AgentStatusBoard: Equatable {
    /// 마지막 status 이후 이만큼 새 status 도 답도 없으면 지운다.
    public static let ttl: TimeInterval = 5 * 60

    public struct Entry: Equatable, Identifiable {
        public let sender: DeviceID
        public let text: String
        public let seq: Int64
        /// 만료 기준 시각 = 릴레이 기록 시각, 단 이 기기 시계보다 미래로는 두지 않는다.
        public let at: Date
        public var id: DeviceID { sender }
        public init(sender: DeviceID, text: String, seq: Int64, at: Date) {
            self.sender = sender; self.text = text; self.seq = seq; self.at = at
        }
    }

    public private(set) var entries: [DeviceID: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// 남아 있는 status 중 가장 앞선 seq — 그 뒤에 저장된 글로 소멸을 판정한다(`clear`).
    public var oldestSeq: Int64? { entries.values.map(\.seq).min() }

    /// status 한 줄을 반영한다. 빈 줄·더 앞선 seq 는 무시. 반환 = 보이는 내용이 바뀌었는가.
    @discardableResult
    public mutating func apply(_ line: AgentStatusLine, now: Date = Date()) -> Bool {
        let text = String(line.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(StatusFormat.maxTextLength))
        guard !line.sender.isEmpty, !text.isEmpty else { return false }
        let previous = entries[line.sender]
        if let previous, previous.seq > line.seq { return false }
        entries[line.sender] = Entry(sender: line.sender, text: text, seq: line.seq, at: min(line.sentAt, now))
        return previous?.text != text
    }

    /// 보낸이의 일반 메시지(seq)가 저장됐다 — 그보다 앞선 그 보낸이의 status 를 지운다. 반환 = 지웠는가.
    @discardableResult
    public mutating func clear(sender: DeviceID, seq: Int64) -> Bool {
        guard let current = entries[sender], current.seq < seq else { return false }
        entries[sender] = nil
        return true
    }

    /// `ttl` 이 지난 말풍선을 지운다.
    public mutating func expire(now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.at) <= Self.ttl }
    }

    /// 대화 목록 미리보기 줄(오너 결정 2026-10-30): 보이는 말풍선 중 가장 최근(seq 최대) status 본문, 없으면 nil —
    /// nil 이면 목록은 평소 미리보기(마지막 저장 글)로 돌아간다. 안 읽음·정렬·알림에는 쓰지 않는다.
    public static func listLine(_ visible: [Entry]) -> String? {
        visible.max(by: { $0.seq < $1.seq })?.text
    }

    /// 지금 보일 말풍선 — 오래된 status 부터(타임라인 맨 아래에 이 순서로 붙인다).
    public func visible(now: Date = Date()) -> [Entry] {
        entries.values.filter { now.timeIntervalSince($0.at) <= Self.ttl }.sorted { $0.seq < $1.seq }
    }
}
