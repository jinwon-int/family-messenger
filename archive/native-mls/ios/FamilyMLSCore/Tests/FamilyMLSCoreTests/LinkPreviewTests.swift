// 링크 미리보기(#683 2단계 계약 v1 · #690 계약 v2) — 응답 디코드 · 이미지 경로 검증 · 요청 URL/인증 헤더.
// 실제 왕복은 RelayTransportTests 와 같은 이유(Linux corelibs URLSession 모킹 불가)로 순수 함수만 고정한다.
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FamilyMLSCore

final class LinkPreviewTests: XCTestCase {
    private let baseURL = URL(string: "https://relay.example.com")!
    private func transport(_ credential: RelayCredential, base: URL? = nil) -> URLSessionRelayTransport {
        URLSessionRelayTransport(baseURL: base ?? baseURL, credential: credential)
    }
    private func decode(_ json: String) throws -> LinkPreview {
        try transport(.bearer("t")).decode(LinkPreview.self, Data(json.utf8))
    }

    // MARK: - 응답 디코드

    func testDecodesFullResponse() throws {
        let preview = try decode(#"{"url":"https://x.com/jack/status/20","site":"X","title":"jack on X","description":"just setting up my twttr","image":"/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%2Fmedia%2FAbC.jpg"}"#)
        XCTAssertEqual(preview, LinkPreview(url: "https://x.com/jack/status/20", site: "X", title: "jack on X",
                                            description: "just setting up my twttr",
                                            image: "/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%2Fmedia%2FAbC.jpg"))
        XCTAssertEqual(preview.shownTitle, "jack on X")
        XCTAssertEqual(preview.shownDescription, "just setting up my twttr")
        XCTAssertEqual(preview.shownSite, "X")
        XCTAssertTrue(preview.hasText)
    }

    /// #690 계약 v2: 응답 모양은 v1 그대로 + `site` 이름(카드에 작게). 비면 nil.
    func testV2ResponseCarriesSiteName() throws {
        let preview = try decode(#"{"url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","site":"YouTube","title":"t","description":null,"image":"/v2/preview/image?u=https%3A%2F%2Fi.ytimg.com%2Fvi%2FdQw4w9WgXcQ%2Fhqdefault.jpg"}"#)
        XCTAssertEqual(preview.shownSite, "YouTube")
        XCTAssertEqual(LinkPreview.imageSource(preview.image ?? ""), "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        XCTAssertNil(try decode(#"{"site":"  ","title":"t"}"#).shownSite)
        XCTAssertNil(try decode(#"{"title":"t"}"#).shownSite)
    }

    func testV2PreviewRequestSendsTheLinkAsWritten() throws {
        let link = URL(string: "https://ko.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8?action=x")!
        let request = try transport(.bearer("t")).linkPreviewRequest(url: link)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://relay.example.com/v2/preview?url=https%3A%2F%2Fko.wikipedia.org%2Fwiki%2F%25EC%2584%259C%25EC%259A%25B8%3Faction%3Dx")
    }

    func testImageNullAndMissingKeysDecodeAsNil() throws {
        let noImage = try decode(#"{"url":"https://x.com/jack/status/20","site":"X","title":"t","description":"d","image":null}"#)
        XCTAssertNil(noImage.image, "image null → 글만 카드")
        XCTAssertTrue(noImage.hasText)
        let titleOnly = try decode(#"{"url":"https://x.com/a/status/1","site":"X","title":"제목만","image":null}"#)
        XCTAssertEqual(titleOnly.shownTitle, "제목만")
        XCTAssertNil(titleOnly.shownDescription)
        XCTAssertTrue(titleOnly.hasText)
    }

    func testBlankTextMeansNoCard() throws {
        let blank = try decode(#"{"url":"https://x.com/a/status/1","site":"X","title":"  ","description":"\n","image":null}"#)
        XCTAssertNil(blank.shownTitle)
        XCTAssertNil(blank.shownDescription)
        XCTAssertFalse(blank.hasText)
        XCTAssertFalse(try decode("{}").hasText)
    }

    func testNonJSONBodyIsDecodingError() {
        XCTAssertThrowsError(try decode("<html>Sign in</html>")) { error in
            guard case .decoding? = error as? RelayError else { return XCTFail("\(error)") }
        }
    }

    /// 실패 응답은 다른 라우트와 같은 매핑 — 앱은 모두 「카드 없이 링크만」.
    func testFailureStatusesMapLikeOtherRoutes() {
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 404, data: Data(#"{"error":"no_preview"}"#.utf8)),
                       .refused(code: "no_preview", status: 404))
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 404, data: Data("404 page not found\n".utf8)),
                       .refused(code: "http_404", status: 404), "라우트 없음(-link-preview off)")
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 502, data: Data(#"{"error":"upstream_failed"}"#.utf8)),
                       .refused(code: "upstream_failed", status: 502))
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 400, data: Data(#"{"error":"bad_url"}"#.utf8)),
                       .refused(code: "bad_url", status: 400))
    }

    // MARK: - 이미지 경로 검증

    func testImageSourceAcceptsRelayRelativePathToTwimg() {
        XCTAssertEqual(LinkPreview.imageSource("/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%2Fmedia%2FAbC.jpg%3Fname%3Dsmall"),
                       "https://pbs.twimg.com/media/AbC.jpg?name=small")
        XCTAssertEqual(LinkPreview.imageSource("/v2/preview/image?u=https%3A%2F%2Fabs.twimg.com%2Fx.png"), "https://abs.twimg.com/x.png")
        XCTAssertEqual(LinkPreview.imageSource("/v2/preview/image?u=https%3A%2F%2FPBS.twimg.com%2Fa.jpg"), "https://PBS.twimg.com/a.jpg")
    }

    /// #690 계약 v2: 이미지 호스트 허용 목록은 릴레이가 판정한다(사이트가 늘어도 앱을 고치지 않게) — 클라이언트는 모양만 본다.
    func testImageSourceAcceptsV2SiteImageHostsShapeOnly() {
        for host in ["i.ytimg.com", "imgnews.pstatic.net", "upload.wikimedia.org", "thumb.wikimedia.org",
                     "opengraph.githubassets.com", "avatars.githubusercontent.com", "ichef.bbci.co.uk"] {
            XCTAssertEqual(LinkPreview.imageSource("/v2/preview/image?u=https%3A%2F%2F\(host)%2Fa.jpg"), "https://\(host)/a.jpg", host)
        }
    }

    func testImageSourceRejectsOtherShapes() {
        for bad in [
            "https://evil.example/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%2Fa.jpg",   // 절대 주소
            "//evil.example/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%2Fa.jpg",          // 스킴 상대
            "/v2/preview/imagex?u=https%3A%2F%2Fpbs.twimg.com%2Fa.jpg",
            "/v2/preview/image/../../v2/me?u=https%3A%2F%2Fpbs.twimg.com%2Fa.jpg",
            "/v2/preview/image",
            "/v2/preview/image?x=https%3A%2F%2Fpbs.twimg.com%2Fa.jpg",
            "/v2/preview/image?u=http%3A%2F%2Fpbs.twimg.com%2Fa.jpg",
            "/v2/preview/image?u=https%3A%2F%2F127.0.0.1%2Fa.jpg",                          // IP — 평범한 호스트 이름 아님
            "/v2/preview/image?u=https%3A%2F%2Flocalhost%2Fa.jpg",
            "/v2/preview/image?u=https%3A%2F%2F%5B%3A%3A1%5D%2Fa.jpg",
            "/v2/preview/image?u=https%3A%2F%2Fuser%40pbs.twimg.com%2Fa.jpg",
            "/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%3A8443%2Fa.jpg",
            "",
        ] {
            XCTAssertNil(LinkPreview.imageSource(bad), bad)
        }
    }

    // MARK: - 요청 (계약 v1: 릴레이 기준 주소 + /v2/preview…, 같은 인증 헤더)

    func testPreviewRequestEncodesWholeURLAndCarriesAuth() throws {
        let url = URL(string: "https://x.com/jack/status/20?s=20&t=a+b")!
        let bearer = try transport(.bearer("jwt-x")).linkPreviewRequest(url: url)
        XCTAssertEqual(bearer.httpMethod, "GET")
        XCTAssertEqual(bearer.url?.absoluteString,
                       "https://relay.example.com/v2/preview?url=https%3A%2F%2Fx.com%2Fjack%2Fstatus%2F20%3Fs%3D20%26t%3Da%2Bb")
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"), "jwt-x")
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(bearer.httpBody)
        let cookie = try transport(.accessCookie("jwt-c")).linkPreviewRequest(url: url)
        XCTAssertEqual(cookie.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=jwt-c")
        XCTAssertNil(cookie.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"))
    }

    func testPreviewRequestKeepsRelayBasePath() throws {
        let request = try transport(.bearer("t"), base: URL(string: "https://example.com/relay/")!)
            .linkPreviewRequest(url: URL(string: "https://x.com/a/status/1")!)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/relay/v2/preview?url=https%3A%2F%2Fx.com%2Fa%2Fstatus%2F1")
    }

    func testImageRequestRebuildsOnRelayWithSameAuth() throws {
        let path = "/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%2Fmedia%2FAbC.jpg%3Fformat%3Djpg%26name%3Dsmall"
        let bearer = try transport(.bearer("jwt-x")).linkPreviewImageRequest(path: path)
        XCTAssertEqual(bearer.httpMethod, "GET")
        XCTAssertEqual(bearer.url?.absoluteString,
                       "https://relay.example.com/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%2Fmedia%2FAbC.jpg%3Fformat%3Djpg%26name%3Dsmall")
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"), "jwt-x")
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Accept"), "image/jpeg, image/png, image/webp, image/gif")
        let cookie = try transport(.accessCookie("jwt-c")).linkPreviewImageRequest(path: path)
        XCTAssertEqual(cookie.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=jwt-c")
    }

    func testImageRequestRefusesPathsOutsideTheContract() {
        for bad in ["https://evil.example/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%2Fa.jpg",
                    "/v2/preview/image?u=https%3A%2F%2F127.0.0.1%2Fa.jpg"] {
            XCTAssertThrowsError(try transport(.bearer("t")).linkPreviewImageRequest(path: bad), bad) {
                XCTAssertEqual($0 as? RelayError, .refused(code: "bad_url", status: 400))
            }
        }
    }

    /// 미리보기 라우트를 구현하지 않은 전송(옛 테스트 대역)은 프로토콜 기본 구현이 404 — 앱은 카드 없이 링크만.
    func testTransportWithoutPreviewDefaultsTo404() async {
        final class Legacy: RelayTransport {
            func postKeyPackages(room: RoomID, _ post: KeyPackagePost) async throws -> KeyPackagesResponse { KeyPackagesResponse(stored: 0, duplicates: 0) }
            func consumeKeyPackage(room: RoomID, device: DeviceID, target: DeviceID) async throws -> StoredKeyPackage? { nil }
            func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse { throw RelayError.network("n/a") }
            func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage { throw RelayError.network("n/a") }
            func closeRoom(room: RoomID, device: DeviceID) async throws {}
            func listRooms(device: DeviceID) async throws -> RoomsResponse { RoomsResponse(rooms: []) }
            func registerPush(_ registration: PushRegistration) async throws {}
            func unregisterPush(device: DeviceID) async throws {}
        }
        let legacy = Legacy()
        await XCTAssertThrowsErrorAsync(try await legacy.linkPreview(url: URL(string: "https://x.com/a/status/1")!)) {
            XCTAssertEqual($0 as? RelayError, .refused(code: "not_found", status: 404))
        }
        await XCTAssertThrowsErrorAsync(try await legacy.linkPreviewImage(path: "/v2/preview/image?u=x")) {
            XCTAssertEqual($0 as? RelayError, .refused(code: "not_found", status: 404))
        }
    }
}
