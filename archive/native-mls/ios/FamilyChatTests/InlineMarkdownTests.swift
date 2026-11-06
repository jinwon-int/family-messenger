import XCTest
@testable import FamilyChat

/// #711: 에이전트 말풍선 줄 안 서식을 구간마다 직접 건다(굵게만 보이고 기울임·코드는 일반 글씨이던 결함).
final class InlineMarkdownTests: XCTestCase {
    typealias S = InlineMarkdown.Segment

    func testPlainTextIsOneUnstyledSegment() {
        XCTAssertEqual(InlineMarkdown.segments("그냥 글자"), [S(text: "그냥 글자")])
    }

    func testBoldItalicCodeStrikeAreSeparateSegments() {
        XCTAssertEqual(
            InlineMarkdown.segments("**굵게** 가 *italic* 나 `code iIl1` 다 ~~취소~~"),
            [
                S(text: "굵게", bold: true),
                S(text: " 가 "),
                S(text: "italic", italic: true),
                S(text: " 나 "),
                S(text: "code iIl1", code: true),
                S(text: " 다 "),
                S(text: "취소", strike: true),
            ]
        )
    }

    func testBoldAndItalicTogether() {
        XCTAssertEqual(InlineMarkdown.segments("***둘 다***"), [S(text: "둘 다", bold: true, italic: true)])
    }

    func testMarkersInsideCodeStayLiteral() {
        XCTAssertEqual(InlineMarkdown.segments("`a*b*c`"), [S(text: "a*b*c", code: true)])
    }

    func testLinkKeepsOnlyItsText() {
        XCTAssertEqual(InlineMarkdown.segments("[링크 글자](https://example.com) 끝"), [S(text: "링크 글자 끝")])
    }

    func testLoneAsteriskIsText() {
        XCTAssertEqual(InlineMarkdown.segments("3 * 4"), [S(text: "3 * 4")])
    }

    func testSegmentsJoinBackToTheVisibleText() {
        let source = "**굵게** 일반 *기울임* `코드`"
        XCTAssertEqual(InlineMarkdown.segments(source).map(\.text).joined(), "굵게 일반 기울임 코드")
    }
}
