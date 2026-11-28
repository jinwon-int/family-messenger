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

    /// 답장 글(2026-11-09): 복사·공유·답장 요약은 인용 머리를 뺀 내 글만.
    func testReplyCopiesOnlyTheReplyText() {
        let body = ReplyQuote.compose(name: "엄마", original: "내일 몇 시에 와?", reply: "7시쯤!")
        XCTAssertEqual(MessageCopy.text(of: record(.text, body)), "7시쯤!")
        let target = ReplyTarget(name: "아빠", seq: 1, original: MessageCopy.text(of: record(.text, body))!)
        XCTAssertEqual(target.snippet, "7시쯤!", "답장에 다시 답하면 안쪽 글만 인용")
        XCTAssertEqual(MessageCopy.text(of: record(.text, "> 인용만")), "> 인용만", "답장이 아닌 인용 글은 그대로")
    }

    func testBlankTextHasNoCopyMenu() {
        XCTAssertNil(MessageCopy.text(of: record(.text, "")))
        XCTAssertNil(MessageCopy.text(of: record(.text, " \n\t")))
    }

    // 「선택해서 복사」 창의 키보드 블록 선택이 화면을 따라가는 쪽(2026-11-28 오너 실기기: Shift+↓ 로 늘리면 아래가 안 보임).
    func testSelectionFollowTracksTheEndWhenExtendingDown() {
        // 커서 10 → Shift+↓ 로 [10, 15) → 끝(15)을 따라간다. 한 번 더 내려 [10, 40) → 40.
        XCTAssertEqual(SelectionFollow.movingOffset(old: NSRange(location: 10, length: 0), new: NSRange(location: 10, length: 5)), 15)
        XCTAssertEqual(SelectionFollow.movingOffset(old: NSRange(location: 10, length: 5), new: NSRange(location: 10, length: 30)), 40)
        // 아래로 잡은 블록을 Shift+↑ 로 줄여도 움직이는 쪽은 끝.
        XCTAssertEqual(SelectionFollow.movingOffset(old: NSRange(location: 10, length: 30), new: NSRange(location: 10, length: 12)), 22)
    }

    func testSelectionFollowTracksTheStartWhenExtendingUp() {
        // 커서 50 → Shift+↑ 로 [42, 50) → 시작(42). 한 번 더 올려 [20, 50) → 20.
        XCTAssertEqual(SelectionFollow.movingOffset(old: NSRange(location: 50, length: 0), new: NSRange(location: 42, length: 8)), 42)
        XCTAssertEqual(SelectionFollow.movingOffset(old: NSRange(location: 42, length: 8), new: NSRange(location: 20, length: 30)), 20)
    }

    func testSelectionFollowAcrossTheAnchor() {
        // 기준점 10 에서 아래로 [10, 15) 잡다가 위로 넘겨 [8, 10) → 시작(8). 다시 아래로 넘겨 [10, 25) → 끝(25).
        XCTAssertEqual(SelectionFollow.movingOffset(old: NSRange(location: 10, length: 5), new: NSRange(location: 8, length: 2)), 8)
        XCTAssertEqual(SelectionFollow.movingOffset(old: NSRange(location: 8, length: 2), new: NSRange(location: 10, length: 15)), 25)
    }

    func testSelectionFollowCaretAndUndecidable() {
        // 블록을 풀고 커서만 움직이면 그 위치.
        XCTAssertEqual(SelectionFollow.movingOffset(old: NSRange(location: 10, length: 5), new: NSRange(location: 15, length: 0)), 15)
        // 커서가 가운데 있을 때 ⌘A(양 끝이 모두 바뀜)·손가락으로 다른 곳을 고름 → UIKit 기본 동작에 맡긴다.
        XCTAssertNil(SelectionFollow.movingOffset(old: NSRange(location: 30, length: 0), new: NSRange(location: 0, length: 100)))
        XCTAssertNil(SelectionFollow.movingOffset(old: NSRange(location: 10, length: 5), new: NSRange(location: 60, length: 4)))
        // 선택이 그대로면(같은 범위 재통지) 움직인 끝이 없다.
        XCTAssertNil(SelectionFollow.movingOffset(old: NSRange(location: 10, length: 5), new: NSRange(location: 10, length: 5)))
    }
}
