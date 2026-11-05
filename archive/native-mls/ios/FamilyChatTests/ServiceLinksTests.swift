import XCTest
import FamilyMLSCore
@testable import FamilyChat

extension PreviewSites {
    /// 이슈 #690 계약 v2 레지스트리(릴레이 `GET /v2/preview/sites` 가 줄 목록) — 앱 테스트 고정값.
    static let contractV2 = PreviewSites(sites: [
        PreviewSite(id: "x", name: "X", hosts: PreviewSites.xHosts, preview: true),
        PreviewSite(id: "youtube", name: "YouTube", hosts: ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"], preview: true),
        PreviewSite(id: "naver-news", name: "네이버 뉴스", hosts: ["n.news.naver.com", "news.naver.com", "m.news.naver.com"], preview: true),
        PreviewSite(id: "wikipedia", name: "위키백과",
                    hosts: ["ko.wikipedia.org", "en.wikipedia.org", "ko.m.wikipedia.org", "en.m.wikipedia.org"], preview: true),
        PreviewSite(id: "github", name: "GitHub", hosts: ["github.com", "www.github.com"], preview: true),
        PreviewSite(id: "bbc", name: "BBC", hosts: ["bbc.com", "www.bbc.com", "bbc.co.uk", "www.bbc.co.uk"], preview: true),
        PreviewSite(id: "threads", name: "Threads", hosts: ["threads.net", "www.threads.net", "threads.com", "www.threads.com"], preview: false),
        PreviewSite(id: "reuters", name: "Reuters", hosts: ["reuters.com", "www.reuters.com"], preview: false),
    ])
}

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

    // MARK: x.com 계열 (#683)

    func testXLinksInBothHostSets() {
        let text = "이거 봐 https://x.com/jack/status/20 그리고 https://twitter.com/i/web/status/1?s=20."
        for hosts in [ServiceLinks.hosts, ServiceLinks.xHosts] {
            XCTAssertEqual(ServiceLinks.links(in: text, hosts: hosts).map { $0.url.absoluteString },
                           ["https://x.com/jack/status/20", "https://twitter.com/i/web/status/1?s=20"])
            let attributed = ServiceLinks.attributed(text, hosts: hosts)
            XCTAssertEqual(String(attributed.characters), text)
        }
        for host in ["www.x.com", "mobile.x.com", "www.twitter.com", "mobile.twitter.com"] {
            XCTAssertNotNil(ServiceLinks.allowedURL("https://\(host)/a/status/1", hosts: ServiceLinks.xHosts), host)
        }
    }

    func testPersonBubbleHostsLeaveInstagramLookalikesAndHttpAsText() {
        for bad in [
            "https://www.instagram.com/p/A/",
            "http://x.com/a/status/1",
            "https://x.com.evil.example/a",
            "https://evilx.com/a",
            "https://t.co/abc",
            "https://user@x.com/a",
            "https://x.com:444/a",
        ] {
            XCTAssertTrue(ServiceLinks.links(in: "보기 \(bad) 끝", hosts: ServiceLinks.xHosts).isEmpty, bad)
        }
        XCTAssertFalse(ServiceLinks.xHosts.contains("instagram.com"))
        XCTAssertNotNil(ServiceLinks.allowedURL("https://x.com/a/status/1"))  // 기본(서비스 봇) 집합에도 포함
    }

    // MARK: 사이트 목록 v2 (#690)

    func testFallbackHostsAreV1() {
        XCTAssertEqual(ServiceLinks.personHosts(.fallback), ServiceLinks.xHosts)
        XCTAssertEqual(ServiceLinks.serviceHosts(.fallback), ServiceLinks.hosts)
        XCTAssertEqual(ServiceLinks.hosts, ServiceLinks.instagramHosts.union(ServiceLinks.xHosts))
        XCTAssertTrue(ServiceLinks.links(in: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", hosts: ServiceLinks.personHosts(.fallback)).isEmpty,
                      "목록을 받기 전엔 v1 그대로 — YouTube 는 글")
    }

    func testPersonHostsAreUnionOfAllSitesIncludingLinkOnly() {
        let text = "스레드 https://www.threads.net/t/AbC 로이터 https://www.reuters.com/world/asia/ 영상 https://youtu.be/dQw4w9WgXcQ "
            + "기사 https://n.news.naver.com/article/001/0012345678 인스타 https://www.instagram.com/p/A/ 위키 https://ko.wikipedia.org/wiki/A"
        let person = ServiceLinks.personHosts(.contractV2)
        XCTAssertEqual(ServiceLinks.links(in: text, hosts: person).map { $0.url.absoluteString },
                       ["https://www.threads.net/t/AbC", "https://www.reuters.com/world/asia/", "https://youtu.be/dQw4w9WgXcQ",
                        "https://n.news.naver.com/article/001/0012345678", "https://ko.wikipedia.org/wiki/A"],
                       "링크만 사이트(Threads·Reuters)도 링크, 인스타그램은 사람 말풍선에서 글")
        XCTAssertEqual(String(ServiceLinks.attributed(text, hosts: person).characters), text)
        for host in ["threads.com", "www.threads.com", "threads.net", "reuters.com", "github.com", "www.bbc.co.uk", "en.m.wikipedia.org", "x.com"] {
            XCTAssertNotNil(ServiceLinks.allowedURL("https://\(host)/a", hosts: person), host)
        }
        XCTAssertFalse(person.contains("instagram.com"))

        let service = ServiceLinks.serviceHosts(.contractV2)
        XCTAssertEqual(ServiceLinks.links(in: text, hosts: service).count, 6, "서비스 봇 = 인스타그램 + 합집합")
        XCTAssertTrue(service.isSuperset(of: person))
        XCTAssertTrue(service.isSuperset(of: ServiceLinks.instagramHosts))
    }

    func testV2HostsStillRejectHttpUserInfoPortsAndLookalikes() {
        let person = ServiceLinks.personHosts(.contractV2)
        for bad in [
            "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtube.com.evil.example/watch",
            "https://evilyoutube.com/watch",
            "https://user@github.com/a/b",
            "https://github.com:444/a/b",
            "https://de.wikipedia.org/wiki/A",
            "https://news.naver.com.evil.example/a",
            "https://bbc.co.uk.evil.example/news",
            "https://t.co/abc",
        ] {
            XCTAssertTrue(ServiceLinks.links(in: "보기 \(bad) 끝", hosts: person).isEmpty, bad)
        }
    }
}
