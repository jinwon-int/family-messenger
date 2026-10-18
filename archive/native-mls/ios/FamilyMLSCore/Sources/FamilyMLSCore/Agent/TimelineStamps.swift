// 메시지 시간 표시 규칙(#405) — 순수 로직(Linux `swift test`). 기준 시각은 MessageRecord.receivedAt
// (동기화된 글 = 릴레이 기록 시각, 내 글 = 보낸 순간).
//   · 시간: 같은 기기가 같은 분 안에 연달아 보낸 묶음의 **마지막** 행에만(메신저 관례 — 줄마다 찍으면 시끄럽다).
//   · 날짜 구분선: 첫 행, 그리고 앞 행과 달력 날짜가 바뀌는 행 위에.
import Foundation

public enum TimelineStamps {
    public struct Stamp: Equatable {
        /// 이 행 옆에 시간을 보인다.
        public let showTime: Bool
        /// 이 행 위에 날짜 구분선을 둔다(그날 0시). nil = 같은 날 이어짐.
        public let dayStart: Date?
        public init(showTime: Bool, dayStart: Date?) { self.showTime = showTime; self.dayStart = dayStart }
    }

    public static func compute(_ records: [MessageRecord], calendar: Calendar) -> [Int64: Stamp] {
        var out: [Int64: Stamp] = [:]
        for (i, record) in records.enumerated() {
            let previous = i > 0 ? records[i - 1] : nil
            let next = i + 1 < records.count ? records[i + 1] : nil
            let newDay = previous.map { !calendar.isDate($0.receivedAt, inSameDayAs: record.receivedAt) } ?? true
            let showTime = next.map { !sameGroup(record, $0, calendar: calendar) } ?? true
            out[record.seq] = Stamp(showTime: showTime, dayStart: newDay ? calendar.startOfDay(for: record.receivedAt) : nil)
        }
        return out
    }

    /// 같은 기기 · 같은 분(달력 기준) — 한 묶음.
    static func sameGroup(_ a: MessageRecord, _ b: MessageRecord, calendar: Calendar) -> Bool {
        a.senderDevice == b.senderDevice
            && calendar.isDate(a.receivedAt, equalTo: b.receivedAt, toGranularity: .minute)
    }
}
