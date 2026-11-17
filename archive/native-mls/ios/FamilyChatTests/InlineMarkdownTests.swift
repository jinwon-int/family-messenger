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

    /// 오너 2026-11-16: 에이전트가 준 주소는 어떤 호스트든 누를 수 있게 — `[글자](주소)` 는 글자에 링크.
    func testMarkdownLinkKeepsHttpURL() {
        XCTAssertEqual(InlineMarkdown.segments("[링크 글자](https://example.com) 끝"),
                       [S(text: "링크 글자", link: URL(string: "https://example.com")), S(text: " 끝")])
    }

    func testMarkdownLinkWithOtherSchemeKeepsOnlyItsText() {
        XCTAssertEqual(InlineMarkdown.segments("[눌러](javascript:alert(1)) 끝").compactMap(\.link), [])
        XCTAssertEqual(InlineMarkdown.segments("[상대](/x) 끝"), [S(text: "상대 끝")])
    }

    func testBareURLBecomesLinkInPlainAndStyledText() {
        XCTAssertEqual(InlineMarkdown.segments("대시보드 http://100.64.0.1:8080/status 확인"), [
            S(text: "대시보드 "),
            S(text: "http://100.64.0.1:8080/status", link: URL(string: "http://100.64.0.1:8080/status")),
            S(text: " 확인"),
        ])
        let bold = InlineMarkdown.segments("**굵게** https://example.org/a.")
        XCTAssertEqual(bold.compactMap(\.link), [URL(string: "https://example.org/a")!])
        XCTAssertEqual(bold.map(\.text).joined(), "굵게 https://example.org/a.")
    }

    func testURLInsideCodeStaysText() {
        XCTAssertEqual(InlineMarkdown.segments("`https://example.org` 코드"), [S(text: "https://example.org", code: true), S(text: " 코드")])
    }

    func testLoneAsteriskIsText() {
        XCTAssertEqual(InlineMarkdown.segments("3 * 4"), [S(text: "3 * 4")])
    }

    func testSegmentsJoinBackToTheVisibleText() {
        let source = "**굵게** 일반 *기울임* `코드`"
        XCTAssertEqual(InlineMarkdown.segments(source).map(\.text).joined(), "굵게 일반 기울임 코드")
    }

    // MARK: 사람 말풍선의 서식 글(전달·붙여넣은 에이전트 보고서) — 링크는 사람 규칙(#690) 그대로

    private let xOnly: Set<String> = ["x.com"]

    func testPersonMarkdownLinkToAllowedHostStaysLink() {
        XCTAssertEqual(InlineMarkdown.segments("[글](https://x.com/a/status/1)", personHosts: xOnly),
                       [S(text: "글", link: URL(string: "https://x.com/a/status/1"))])
    }

    func testPersonMarkdownLinkToOtherHostBecomesTextWithAddress() {
        XCTAssertEqual(InlineMarkdown.segments("[PR](https://github.com/o/r/pull/1) 끝", personHosts: xOnly),
                       [S(text: "PR (https://github.com/o/r/pull/1) 끝")])
    }

    /// 링크 글자 안 서식은 Apple 파서 몫(iOS 시뮬레이터에선 링크 안 `**` 가 굵게로 오지 않았다) — 여기서는 주소가 한 번만 붙고 링크가 풀리는지만 본다.
    func testPersonStyledLinkAddsAddressOnce() {
        let segments = InlineMarkdown.segments("[**굵게** 글](https://example.com/)", personHosts: xOnly)
        XCTAssertEqual(segments.map(\.text).joined(), "굵게 글 (https://example.com/)")
        XCTAssertTrue(segments.allSatisfy { $0.link == nil })
    }

    func testPersonBareURLOnlyAllowedHostIsLink() {
        XCTAssertEqual(InlineMarkdown.segments("**봐** https://github.com/x 와 https://x.com/a", personHosts: xOnly),
                       [S(text: "봐", bold: true), S(text: " https://github.com/x 와 "), S(text: "https://x.com/a", link: URL(string: "https://x.com/a"))])
    }
}
