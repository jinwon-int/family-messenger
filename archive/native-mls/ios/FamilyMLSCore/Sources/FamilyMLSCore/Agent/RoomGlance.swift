// 대화 목록 "모닥불 카드" 한 장의 요약(#405 P2) — 순수 로직(Linux `swift test`).
// 마지막 글(미리보기) · 불가에 둘러앉은 사람(actor)과 에이전트(기기) · 에이전트가 있는 자리인가.
// 웹 room-order.js 처럼 목록 순서는 바꾸지 않는다(displayOrder 그대로) — 카드 모양만 정한다.
import Foundation

public struct RoomGlance: Equatable {
    /// 마지막 글·첨부(열 수 없는 행·시스템 행 제외). 없으면 nil.
    public let last: MessageRecord?
    /// 말한 적 있는 사람 actor(처음 말한 순서). 에이전트 제외.
    public let people: [String]
    /// 말한 적 있는 에이전트 기기(처음 말한 순서).
    public let agents: [DeviceID]

    public var hasAgent: Bool { !agents.isEmpty }

    /// 점(둘러앉은 자리)은 이만큼만 그린다.
    public static let maxSeats = 6

    public static func make(_ records: [MessageRecord], roster: AgentRoster) -> RoomGlance {
        var people: [String] = []
        var agents: [DeviceID] = []
        var last: MessageRecord?
        for record in records where record.kind == .text || record.kind.isFile {
            last = record
            if roster.isAgent(record) {
                if !agents.contains(record.senderDevice) { agents.append(record.senderDevice) }
            } else if !people.contains(record.senderActor) {
                people.append(record.senderActor)
            }
        }
        return RoomGlance(last: last, people: people, agents: agents)
    }
}

public enum DeviceLabel {
    /// 기기 ID 의 둘째 마디 = 기기 종류(`owner-iphone-27a879` → "iphone", `owner-pc` → "pc"). 없으면 nil.
    public static func kind(_ device: DeviceID) -> String? {
        let parts = device.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        let kind = String(parts[1]).lowercased()
        return kind.isEmpty ? nil : kind
    }
}
