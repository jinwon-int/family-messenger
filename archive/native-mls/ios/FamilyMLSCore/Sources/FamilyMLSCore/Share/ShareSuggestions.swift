// #666 공유 시트 맨 윗줄 대화 추천 — 순수 규칙(Linux 에서 테스트). Intents 기부 자체는 앱의 Apple 전용 파일(`ShareSuggestionDonor.live`).
//
// - 대화 식별자 = `<서버 스코프 ID>/<방 ID>`: 서버를 바꾸면 옛 식별자는 지금 스코프와 맞지 않아 자연히 무효다(확장이 거른다).
// - 추천 대상 = 공유 확장의 방 목록(`ShareHandoff.targets`, D3)과 같은 집합. 목록에서 빠진 방(정지·탈퇴)은 추천에서도 내린다.
// - 연락처 사진·실명은 기부하지 않는다(방 표시 이름만) — Intents 저장소는 기기 밖으로 나가지 않지만 가족 사진을 거기 두지 않는다.
import Foundation

public enum ShareSuggestions {
    /// `INSendMessageIntent.conversationIdentifier`(= `INInteraction.groupIdentifier`).
    public static func conversation(scope: String, room: RoomID) -> String { "\(scope)/\(room)" }

    /// 확장이 받은 식별자에서 방 ID — 지금 스코프의 것이 아니면 nil(옛 서버의 추천을 눌렀다).
    public static func room(conversation: String, scope: String) -> RoomID? {
        let prefix = scope + "/"
        guard conversation.hasPrefix(prefix) else { return nil }
        let room = String(conversation.dropFirst(prefix.count))
        return room.isEmpty || room.contains("/") ? nil : room
    }

    /// 공유 대상 목록이 바뀌었을 때 추천에서 내릴 방(이전에는 있었고 지금은 없는 방). 순서는 이전 목록 순.
    public static func retired(previous: [RoomID], current: [RoomID]) -> [RoomID] {
        let now = Set(current)
        return previous.filter { !now.contains($0) }
    }
}

/// 앱이 부르는 기부 훅. 기본 = 아무것도 하지 않음(테스트·Linux). `live` 는 `FamilyChat/Intents/ShareSuggestionDonor+Intents.swift`.
public struct ShareSuggestionDonor {
    /// 방을 추천에 올린다(열었을 때·보냈을 때 — 최근순은 iOS 가 기부 시각으로 정한다). `title` = 화면과 같은 방 이름.
    public var donate: (_ conversation: String, _ title: String) -> Void
    /// 추천에서 내린다(대상 목록에서 빠진 방).
    public var delete: (_ conversations: [String]) -> Void
    /// 전부 내린다(서버 전환·이 기기 지우기).
    public var deleteAll: () -> Void

    public init(donate: @escaping (String, String) -> Void = { _, _ in },
                delete: @escaping ([String]) -> Void = { _ in },
                deleteAll: @escaping () -> Void = {}) {
        self.donate = donate; self.delete = delete; self.deleteAll = deleteAll
    }
}
