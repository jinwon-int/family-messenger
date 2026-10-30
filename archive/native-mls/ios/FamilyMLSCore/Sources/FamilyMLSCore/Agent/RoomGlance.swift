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
    /// 오늘의 불 세기 1~3(디자인 1차, TM-3921 「24h 대화량 1~3단계, 숫자 없음」): 최근 24시간 글 수 0~2 → 1, 3~11 → 2, 12 이상 → 3.
    public let fireLevel: Int

    public var hasAgent: Bool { !agents.isEmpty }

    /// 1:1 대화로 보이는가 — 이 방에서 말한 참여자(사람 actor + 에이전트 기기)가 2명 이하. 목록 미리보기의 「이름: 」 접두를
    /// 뺄지 정한다(방 이름이 이미 상대라 중복 — 오너 2026-10-30, 웹 한데 `isOneToOne` 2026-10-26 과 같은 결과).
    /// 웹은 MLS 명단(roster)으로 세지만 iOS 목록은 방마다 엔진을 열지 않으므로 말한 사람으로 근사한다.
    public var isOneToOne: Bool { people.count + agents.count <= 2 }

    /// 점(둘러앉은 자리)은 이만큼만 그린다.
    public static let maxSeats = 6

    public static func make(_ records: [MessageRecord], roster: AgentRoster, now: Date = Date()) -> RoomGlance {
        var people: [String] = []
        var agents: [DeviceID] = []
        var last: MessageRecord?
        var recent = 0
        let dayAgo = now.addingTimeInterval(-24 * 3_600)
        for record in records where record.kind == .text || record.kind.isFile {
            last = record
            if record.receivedAt >= dayAgo { recent += 1 }
            if roster.isAgent(record) {
                if !agents.contains(record.senderDevice) { agents.append(record.senderDevice) }
            } else if !people.contains(record.senderActor) {
                people.append(record.senderActor)
            }
        }
        return RoomGlance(last: last, people: people, agents: agents, fireLevel: fireLevel(recentCount: recent))
    }

    /// 24시간 글 수 → 1~3. 문턱은 가족 방 기준 감(조용함 / 보통 / 활발)이며 숫자는 화면에 내지 않는다.
    public static func fireLevel(recentCount: Int) -> Int {
        recentCount >= 12 ? 3 : recentCount >= 3 ? 2 : 1
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
