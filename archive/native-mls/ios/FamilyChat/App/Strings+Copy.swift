// 말풍선 글 복사·공유·답장(MessageCopy.swift) 화면 문구. 앱 전용 — NSE 소스 목록(project.yml)에 넣지 말 것.
import Foundation

extension Strings {
    static let messageCopy = "복사"
    static let messageSelectCopy = "선택해서 복사"
    static let messageCopyAll = "전체 복사"
    // 말풍선 공유·답장(2026-11-09).
    static let messageShare = "공유"
    static let messageReply = "답장"
    static let replyCancel = "답장 취소"
    static func replyingTo(_ name: String) -> String { name.isEmpty ? "답장" : "\(name)에게 답장" }
    static func replyQuoteLabel(_ quote: String) -> String { "답장한 글: \(quote)" }
    static let replyQuoteOpenHint = "누르면 원래 글로 이동"
    static let replyTargetMissing = "원래 글이 지금 불러온 대화에 없어요. 위로 올려 이전 대화를 불러온 뒤 다시 눌러 보세요."
}
