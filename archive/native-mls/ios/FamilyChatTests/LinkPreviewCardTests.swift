import XCTest
import UIKit
import FamilyMLSCore
@testable import FamilyChat

/// 링크 미리보기(#683 2단계 계약 v1 · #690 계약 v2 클라이언트 절): 대상 링크 표 · 앱 메모리 캐시(실패 포함) · 카드 이미지 높이.
@MainActor
final class LinkPreviewCardTests: XCTestCase {

    // MARK: 대상 — 첫 x.com 상태 글 링크

    func testTargetIsFirstXStatusLink() {
        let cases: [(String, String?)] = [
            ("이거 봐 https://x.com/jack/status/20", "https://x.com/jack/status/20"),
            ("https://twitter.com/i/web/status/1?s=20.", "https://twitter.com/i/web/status/1?s=20"),
            ("https://mobile.x.com/a_b/status/123/photo/1 끝", "https://mobile.x.com/a_b/status/123/photo/1"),
            ("https://www.twitter.com/Jack/status/1/", "https://www.twitter.com/Jack/status/1/"),
            // 상태 글이 아닌 x.com 링크는 건너뛰고 다음 상태 글 링크
            ("프로필 https://x.com/jack 글 https://x.com/a/status/2 또 https://x.com/b/status/3", "https://x.com/a/status/2"),
            ("https://x.com/a/status/1 https://x.com/b/status/2", "https://x.com/a/status/1"),
            // 15자 handle · 25자리 id 는 경계 안
            ("https://x.com/abcdefghijklmno/status/1234567890123456789012345", "https://x.com/abcdefghijklmno/status/1234567890123456789012345"),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(ServiceLinks.previewTarget(in: text)?.absoluteString, expected, text)
        }
    }

    func testNonStatusOrDisallowedLinksHaveNoTarget() {
        for text in [
            "그냥 글",
            "https://x.com/jack",
            "https://x.com/jack/status/",
            "https://x.com/jack/status/abc",
            "https://x.com/jack/statuses/1",
            "https://x.com/jack/Status/1",
            "https://x.com/a-b/status/1",
            "https://x.com/abcdefghijklmnop/status/1",                       // handle 16자
            "https://x.com/a/status/12345678901234567890123456",             // id 26자리
            "https://x.com/i/web/status/x",
            "https://x.com//status/1",
            "http://x.com/a/status/1",
            "https://x.com:444/a/status/1",
            "https://user@x.com/a/status/1",
            "https://evilx.com/a/status/1",
            "https://x.com.evil.example/a/status/1",
            "https://t.co/abc",
            "https://www.instagram.com/a/status/1",
        ] {
            XCTAssertNil(ServiceLinks.previewTarget(in: "보기 \(text) 끝"), text)
        }
    }

    // MARK: 대상 — 사이트 목록 v2 (#690): preview 사이트의 첫 링크, 경로 판정은 릴레이

    func testV2TargetIsFirstLinkOfAPreviewSite() {
        let yt = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let gh = "https://github.com/jinwon-int/family-messenger/issues/690"
        let cases: [(String, String?)] = [
            ("영상 \(yt) 봐", yt),
            ("https://youtu.be/dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ"),
            ("https://m.youtube.com/shorts/dQw4w9WgXcQ.", "https://m.youtube.com/shorts/dQw4w9WgXcQ"),
            ("기사 https://n.news.naver.com/article/001/0012345678 끝", "https://n.news.naver.com/article/001/0012345678"),
            ("https://m.news.naver.com/mnews/article/001/0012345678?sid=100", "https://m.news.naver.com/mnews/article/001/0012345678?sid=100"),
            ("https://ko.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8", "https://ko.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8"),
            ("https://en.m.wikipedia.org/wiki/Seoul", "https://en.m.wikipedia.org/wiki/Seoul"),
            (gh, gh),
            ("https://www.bbc.com/news/articles/c0abcdefgh", "https://www.bbc.com/news/articles/c0abcdefgh"),
            ("https://bbc.co.uk/news/articles/c0abcdefgh", "https://bbc.co.uk/news/articles/c0abcdefgh"),
            ("https://x.com/jack/status/20", "https://x.com/jack/status/20"),
            // 링크만 사이트(Threads·Reuters)는 건너뛰고 다음 preview 사이트 링크
            ("https://www.threads.net/t/AbC 그리고 \(yt)", yt),
            ("https://www.reuters.com/world/ 그리고 \(gh)", gh),
            // 순서대로 첫 것(사이트가 달라도)
            ("\(gh) 그리고 https://x.com/a/status/2", gh),
            ("https://x.com/a/status/2 그리고 \(gh)", "https://x.com/a/status/2"),
            // 경로 규칙은 릴레이 몫 — preview 사이트의 첫 링크를 그대로 묻는다(맞지 않으면 400 → 카드 없음)
            ("https://x.com/jack 그리고 https://x.com/a/status/2", "https://x.com/jack"),
            ("https://www.youtube.com/", "https://www.youtube.com/"),
            // 호스트 대소문자는 무시, 링크는 쓴 그대로
            ("https://WWW.YouTube.com/watch?v=dQw4w9WgXcQ", "https://WWW.YouTube.com/watch?v=dQw4w9WgXcQ"),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(ServiceLinks.previewTarget(in: text, sites: .contractV2)?.absoluteString, expected, text)
        }
    }

    func testV2LinkOnlyAndDisallowedLinksHaveNoTarget() {
        for text in [
            "그냥 글",
            "https://www.threads.net/t/AbC",
            "https://threads.com/t/AbC 그리고 https://www.reuters.com/world/",
            "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
            "https://user@github.com/a/b",
            "https://github.com:444/a/b",
            "https://de.wikipedia.org/wiki/Seoul",
            "https://www.instagram.com/p/A/",
            "https://t.co/abc",
        ] {
            XCTAssertNil(ServiceLinks.previewTarget(in: "보기 \(text) 끝", sites: .contractV2), text)
        }
    }

    /// 목록을 받기 전·실패(폴백)는 v1 — x.com 상태 글 링크만 대상, 새 사이트는 링크도 카드도 아니다.
    func testFallbackTargetKeepsV1XStatusRule() {
        XCTAssertNil(ServiceLinks.previewTarget(in: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", sites: .fallback))
        XCTAssertNil(ServiceLinks.previewTarget(in: "https://x.com/jack", sites: .fallback))
        XCTAssertEqual(ServiceLinks.previewTarget(in: "https://github.com/a/b https://x.com/jack https://x.com/a/status/2", sites: .fallback)?.absoluteString,
                       "https://x.com/a/status/2")
        XCTAssertEqual(ServiceLinks.previewTarget(in: "https://x.com/a/status/2")?.absoluteString, "https://x.com/a/status/2", "기본값 = 폴백")
    }

    /// 릴레이가 x 를 빼면 x 링크는 대상도 링크도 아니다(목록이 기준).
    func testV2ListWithoutXDropsX() {
        let sites = PreviewSites(sites: [PreviewSite(id: "youtube", name: "YouTube", hosts: ["youtu.be"], preview: true)])
        XCTAssertNil(ServiceLinks.previewTarget(in: "https://x.com/a/status/2", sites: sites))
        XCTAssertEqual(ServiceLinks.previewTarget(in: "https://x.com/a/status/2 https://youtu.be/dQw4w9WgXcQ", sites: sites)?.absoluteString,
                       "https://youtu.be/dQw4w9WgXcQ")
    }

    // MARK: 캐시 — 같은 주소는 한 번, 실패도 담는다

    private var url: URL { URL(string: "https://x.com/jack/status/20")! }

    private final class Calls {
        var previews: [URL] = []
        var images: [String] = []
    }

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 2)).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        }.pngData()!
    }

    func testSuccessWithNullImageIsCachedAndAskedOnce() async {
        let store = LinkPreviewStore()
        let calls = Calls()
        let preview = LinkPreview(url: url.absoluteString, site: "X", title: "jack on X", description: "just setting up", image: nil)
        for _ in 0..<3 {
            let outcome = await store.load(url, fetch: { calls.previews.append($0); return preview },
                                           fetchImage: { calls.images.append($0); return Data() })
            XCTAssertEqual(outcome.card?.preview, preview)
            XCTAssertNil(outcome.card?.image, "image null → 글만 카드")
        }
        XCTAssertEqual(calls.previews, [url], "같은 주소는 한 번만 묻는다")
        XCTAssertEqual(calls.images, [], "image null 이면 이미지를 묻지 않는다")
        XCTAssertNotNil(store.cached(url)?.card)
    }

    func testImageIsFetchedThroughTheRelayPath() async {
        let store = LinkPreviewStore()
        let calls = Calls()
        let path = "/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%2Fmedia%2FAbC.jpg"
        let data = png()
        let outcome = await store.load(url, fetch: { _ in LinkPreview(title: "t", image: path) },
                                       fetchImage: { calls.images.append($0); return data })
        XCTAssertEqual(calls.images, [path], "응답 image 경로를 그대로 같은 인증의 전송에 넘긴다")
        XCTAssertNotNil(outcome.card?.image)
    }

    func testImageFailureKeepsTheCardWithoutImage() async {
        let store = LinkPreviewStore()
        let outcome = await store.load(url, fetch: { _ in LinkPreview(description: "본문", image: "/v2/preview/image?u=x") },
                                       fetchImage: { _ in throw RelayError.refused(code: "upstream_failed", status: 502) })
        XCTAssertEqual(outcome.card?.preview.shownDescription, "본문")
        XCTAssertNil(outcome.card?.image)
        let garbage = await LinkPreviewStore().load(url, fetch: { _ in LinkPreview(title: "t", image: "/v2/preview/image?u=x") },
                                                    fetchImage: { _ in Data("not an image".utf8) })
        XCTAssertNotNil(garbage.card)
        XCTAssertNil(garbage.card?.image, "디코드 못 하는 바이트 → 이미지 없는 카드")
    }

    func testFailuresAreCachedAsNoCardThenRetriedAfterTTL() async {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = LinkPreviewStore(failureTTL: 600, now: { clock })
        let calls = Calls()
        for failure in [RelayError.refused(code: "http_404", status: 404), .refused(code: "upstream_failed", status: 502),
                        .network("offline"), .decoding("LinkPreview")] {
            let other = URL(string: "https://x.com/a/status/\(calls.previews.count + 1)")!
            let first = await store.load(other, fetch: { calls.previews.append($0); throw failure }, fetchImage: { _ in Data() })
            XCTAssertNil(first.card, "\(failure) → 카드 없음")
            let again = await store.load(other, fetch: { calls.previews.append($0); throw failure }, fetchImage: { _ in Data() })
            XCTAssertNil(again.card)
            if case .noCard? = store.cached(other) {} else { XCTFail("실패도 캐시한다: \(failure)") }
        }
        XCTAssertEqual(calls.previews.count, 4, "실패한 주소도 TTL 안에서는 다시 묻지 않는다")

        let blank = URL(string: "https://x.com/a/status/99")!
        _ = await store.load(blank, fetch: { calls.previews.append($0); return LinkPreview(title: " ", description: "") }, fetchImage: { _ in Data() })
        XCTAssertNil(store.cached(blank)?.card, "글 없는 응답 → 카드 없음")

        clock = clock.addingTimeInterval(601)
        XCTAssertNil(store.cached(blank), "실패는 10분 뒤 만료")
        let retried = await store.load(blank, fetch: { _ in LinkPreview(title: "이제 됨") }, fetchImage: { _ in Data() })
        XCTAssertEqual(retried.card?.preview.shownTitle, "이제 됨")
        clock = clock.addingTimeInterval(100_000)
        XCTAssertNotNil(store.cached(blank)?.card, "성공은 만료되지 않는다")
    }

    /// #690: 릴레이가 경로 규칙에 안 맞는 링크를 400 `bad_url` 로 거절하면 그 URL 만 음성 캐시(다른 링크는 따로 묻는다).
    func testBadURLIsNegativeCachedPerURL() async {
        let store = LinkPreviewStore()
        let calls = Calls()
        let channel = URL(string: "https://www.youtube.com/channel/abc")!
        let watch = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        for _ in 0..<3 {
            let outcome = await store.load(channel, fetch: { calls.previews.append($0); throw RelayError.refused(code: "bad_url", status: 400) },
                                           fetchImage: { _ in Data() })
            XCTAssertNil(outcome.card)
        }
        XCTAssertEqual(calls.previews, [channel], "400 도 TTL 안에서 다시 묻지 않는다")
        if case .noCard? = store.cached(channel) {} else { XCTFail("400 → 음성 캐시") }
        let ok = await store.load(watch, fetch: { calls.previews.append($0); return LinkPreview(site: "YouTube", title: "영상") },
                                  fetchImage: { _ in Data() })
        XCTAssertEqual(ok.card?.preview.shownSite, "YouTube", "카드에 사이트 이름")
        XCTAssertEqual(calls.previews, [channel, watch])
    }

    func testConcurrentLoadsShareOneRequest() async {
        let store = LinkPreviewStore()
        let calls = Calls()
        let fetch: LinkPreviewStore.FetchPreview = { url in
            calls.previews.append(url)
            await Task.yield()
            return LinkPreview(title: "t")
        }
        let target = url
        // 둘 다 메인 액터에서 돈다 — 두 번째는 첫 번째가 묻는 중(inFlight)에 들어와 그 결과를 기다린다.
        let first = Task { await store.load(target, fetch: fetch, fetchImage: { _ in Data() }).card != nil }
        let second = Task { await store.load(target, fetch: fetch, fetchImage: { _ in Data() }).card != nil }
        let firstHasCard = await first.value
        let secondHasCard = await second.value
        XCTAssertTrue(firstHasCard)
        XCTAssertTrue(secondHasCard)
        XCTAssertEqual(calls.previews.count, 1)
    }

    func testOldestEntriesAreEvictedPastTheLimit() async {
        let store = LinkPreviewStore(limit: 2)
        let urls = (1...3).map { URL(string: "https://x.com/a/status/\($0)")! }
        for u in urls { _ = await store.load(u, fetch: { _ in LinkPreview(title: "t") }, fetchImage: { _ in Data() }) }
        XCTAssertNil(store.cached(urls[0]))
        XCTAssertNotNil(store.cached(urls[1]))
        XCTAssertNotNil(store.cached(urls[2]))
    }

    // MARK: 카드 — 이미지 최대 높이 200, 비율 유지

    func testImageHeightKeepsAspectUpTo200() {
        let inner = LinkPreviewCard.maxWidth - LinkPreviewCard.inset * 2
        XCTAssertEqual(LinkPreviewCard.imageHeight(CGSize(width: 1200, height: 600)), inner / 2, accuracy: 0.001)
        XCTAssertEqual(LinkPreviewCard.imageHeight(CGSize(width: 600, height: 1200)), 200)
        XCTAssertEqual(LinkPreviewCard.imageHeight(.zero), 200)
        XCTAssertEqual(LinkPreviewCard.maxImageHeight, 200)
        XCTAssertEqual(LinkPreviewCard.titleLines, 1)
        XCTAssertEqual(LinkPreviewCard.siteLines, 1)
        XCTAssertEqual(LinkPreviewCard.descriptionLines, 4)
    }
}
