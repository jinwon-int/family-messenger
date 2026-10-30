import XCTest
import FamilyMLSCore
@testable import FamilyChat

/// 말풍선 꾹 누르기 「복사」·「선택해서 복사」 대상(2026-10-30): 글·시스템 줄만, 첨부(설명자·파일 키)·복호화 실패·빈 글은 메뉴 없음.
final class MessageCopyTests: XCTestCase {
    private func record(_ kind: MessageRecord.Kind, _ body: String, attachment: Data? = nil) -> MessageRecord {
        MessageRecord(room: "family", seq: 1, senderDevice: "mom-iphone-a1b2c3", clientId: "c1", kind: kind,
                      body: body, attachment: attachment, receivedAt: Date(), decryptedBy: .app)
    }

    func testTextIsCopiedVerbatimIncludingNewlinesAndMarkdown() {
        let body = "  첫 줄\n**둘째** 줄 https://example.com/a  \n"
        XCTAssertEqual(MessageCopy.text(of: record(.text, body)), body, "보이는 글 그대로(앞뒤 공백·줄바꿈·마크다운 원문 유지)")
        XCTAssertEqual(MessageCopy.text(of: record(.system, "방이 만들어졌습니다")), "방이 만들어졌습니다")
    }

    func testAttachmentsAndUndecryptableHaveNoCopyMenu() {
        let descriptor = Data(#"{"key":"secret-file-key"}"#.utf8)
        XCTAssertNil(MessageCopy.text(of: record(.fileV2, "image/jpeg", attachment: descriptor)), "file-v2 설명자는 글로 내보내지 않는다")
        XCTAssertNil(MessageCopy.text(of: record(.attachment, "photo.jpg", attachment: Data([1, 2, 3]))))
        XCTAssertNil(MessageCopy.text(of: record(.undecryptable, "키 없음")))
    }

    func testBlankTextHasNoCopyMenu() {
        XCTAssertNil(MessageCopy.text(of: record(.text, "")))
        XCTAssertNil(MessageCopy.text(of: record(.text, " \n\t")))
    }
}
