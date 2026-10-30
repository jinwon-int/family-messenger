// status-v1(#560, archive/native-mls/STATUS-V1.md) — 에이전트 작업 상태 한 줄의 와이어 규칙.
//
// 매트릭스 브리지는 `⏳ Working — 10s | Bash: …` 한 줄을 같은 메시지에 덧써 갱신한다. 한데에는 메시지 편집이 없으므로 봇은
// 그 한 줄을 바깥 `client_id = status-<uuid>` 인 application 메시지로 5초마다 새로 보낸다(평문 = 그 한 줄 UTF-8, E2EE 그대로).
// 앱은 이것을 **저장하지 않고**(MessageStore·이력 밖) 보낸이별 임시 말풍선 하나로만 보인다(`AgentStatusBoard`).
// 판정은 웹 `status-v1.js`·봇·릴레이 `status.go` 와 같다: `^status-[a-f0-9-]{36}$`(소문자). 접두만 맞으면 일반 글.
import Foundation

public enum StatusFormat {
    public static let clientIdPrefix = "status-"
    /// 말풍선 한 줄 상한(문자) — 브리지는 8 KiB 까지 보낼 수 있지만 상태 줄은 한 줄짜리다(웹과 같은 500).
    public static let maxTextLength = 500

    /// `status-` + uuid v4 소문자 36자인가(`FileV2Format.isClientId` 와 같은 모양 검사).
    public static func isClientId(_ clientId: String) -> Bool {
        guard clientId.hasPrefix(clientIdPrefix) else { return false }
        let tail = clientId.utf8.dropFirst(clientIdPrefix.utf8.count)
        return tail.count == 36 && tail.allSatisfy { (0x61...0x66).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }
}

/// 동기화가 해독해 넘기는 status 한 줄(`SyncPass.statuses`) — 저장하지 않는다.
public struct AgentStatusLine: Equatable {
    public let sender: DeviceID
    public let text: String
    public let seq: Int64
    /// 릴레이 기록 시각(`created_at`) — 없으면 해독한 순간.
    public let sentAt: Date
    public init(sender: DeviceID, text: String, seq: Int64, sentAt: Date) {
        self.sender = sender; self.text = text; self.seq = seq; self.sentAt = sentAt
    }
}
