import XCTest
@testable import FamilyChat

/// 서비스 봇 말풍선 링크: https + 허용 호스트만(웹 tests/service-links.test.mjs 와 같은 사례).
final class ServiceLinksTests: XCTestCase {
    private func hrefs(_ text: String) -> [String] { ServiceLinks.links(in: text).map { $0.url.absoluteString } }

    func testInstagramLinksBecomeLinksAndTextStays() {
        let text = "• 계정 — 2건\n  - [릴스] \"첫 줄\" https://www.instagram.com/reel/AbC_1-x/\n  - [게시물] \"둘째\" https://instagram.com/p/XyZ/"
        XCTAssertEqual(hrefs(text), ["https://www.instagram.com/reel/AbC_1-x/", "https://instagram.com/p/XyZ/"])
        let attributed = ServiceLinks.attributed(text)
        XCTAssertEqual(String(attributed.characters), text)
        let linked = attributed.runs.compactMap { $0.link }.map { $0.absoluteString }
        XCTAssertEqual(linked, ["https://www.instagram.com/reel/AbC_1-x/", "https://instagram.com/p/XyZ/"])
    }

    func testTrailingPunctuationIsNotPartOfTheLink() {
        XCTAssertEqual(hrefs("보기: https://www.instagram.com/p/AAA/). 끝"), ["https://www.instagram.com/p/AAA/"])
    }

    func testOtherSchemesHostsUserInfoAndPortsStayText() {
        for bad in [
            "http://www.instagram.com/p/A/",
            "https://example.com/p/A/",
            "https://instagram.com.example.com/p/A/",
            "https://evil-instagram.com/p/A/",
            "https://user:pw@www.instagram.com/p/A/",
            "https://www.instagram.com:8443/p/A/",
            "instagram.com/p/A/",
        ] {
            XCTAssertTrue(hrefs("x \(bad) y").isEmpty, bad)
            XCTAssertTrue(ServiceLinks.attributed("x \(bad) y").runs.allSatisfy { $0.link == nil }, bad)
        }
    }

    func testUppercaseHostAllowedAndPlainTextUnchanged() {
        XCTAssertNotNil(ServiceLinks.allowedURL("https://WWW.Instagram.com/p/A/"))
        XCTAssertNil(ServiceLinks.allowedURL("javascript:alert(1)"))
        XCTAssertTrue(hrefs("그냥 글").isEmpty)
        XCTAssertEqual(String(ServiceLinks.attributed("").characters), "")
    }
}
