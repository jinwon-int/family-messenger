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
}
