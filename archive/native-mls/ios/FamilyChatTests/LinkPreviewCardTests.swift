import XCTest
import UIKit
import FamilyMLSCore
@testable import FamilyChat

/// x.com 링크 미리보기(#683 2단계, 이슈 #683 「2단계 API 계약 v1」 클라이언트 절): 대상 링크 표 · 앱 메모리 캐시(실패 포함) · 카드 이미지 높이.
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
        XCTAssertEqual(LinkPreviewCard.descriptionLines, 4)
    }
}
