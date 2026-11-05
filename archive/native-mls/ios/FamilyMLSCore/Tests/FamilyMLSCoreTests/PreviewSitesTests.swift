// 미리보기 사이트 목록(#690 「계약 v2」) — `GET /v2/preview/sites` 엄격 디코드 · 내장 폴백 · 호스트 합집합 · 요청 URL/인증 헤더.
// 실제 왕복은 RelayTransportTests 와 같은 이유(Linux corelibs URLSession 모킹 불가)로 순수 함수만 고정한다.
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FamilyMLSCore

final class PreviewSitesTests: XCTestCase {
    private let baseURL = URL(string: "https://relay.example.com")!
    private func transport(_ credential: RelayCredential, base: URL? = nil) -> URLSessionRelayTransport {
        URLSessionRelayTransport(baseURL: base ?? baseURL, credential: credential)
    }
    private func decode(_ json: String) throws -> PreviewSites {
        try transport(.bearer("t")).decode(PreviewSites.self, Data(json.utf8))
    }

    /// 이슈 #690 계약 v2 레지스트리 그대로의 응답.
    private let contractJSON = #"""
    {"version":2,"sites":[
     {"id":"x","name":"X","hosts":["x.com","www.x.com","mobile.x.com","twitter.com","www.twitter.com","mobile.twitter.com"],"preview":true},
     {"id":"youtube","name":"YouTube","hosts":["youtube.com","www.youtube.com","m.youtube.com","youtu.be"],"preview":true},
     {"id":"naver-news","name":"네이버 뉴스","hosts":["n.news.naver.com","news.naver.com","m.news.naver.com"],"preview":true},
     {"id":"wikipedia","name":"위키백과","hosts":["ko.wikipedia.org","en.wikipedia.org","ko.m.wikipedia.org","en.m.wikipedia.org"],"preview":true},
     {"id":"github","name":"GitHub","hosts":["github.com","www.github.com"],"preview":true},
     {"id":"bbc","name":"BBC","hosts":["bbc.com","www.bbc.com","bbc.co.uk","www.bbc.co.uk"],"preview":true},
     {"id":"threads","name":"Threads","hosts":["threads.net","www.threads.net","threads.com","www.threads.com"],"preview":false},
     {"id":"reuters","name":"Reuters","hosts":["reuters.com","www.reuters.com"],"preview":false}
    ]}
    """#

    private func entry(_ id: String, _ hostsJSON: String, preview: String = "true", name: String = #""N""#) -> String {
        #"{"id":"\#(id)","name":\#(name),"hosts":\#(hostsJSON),"preview":\#(preview)}"#
    }
    private func body(_ entries: [String]) -> String {
        #"{"version":2,"sites":[\#(entries.joined(separator: ","))]}"#
    }

    // MARK: - 디코드 (좋은 응답)

    func testDecodesContractRegistry() throws {
        let sites = try decode(contractJSON)
        XCTAssertFalse(sites.isFallback)
        XCTAssertEqual(sites.sites.map(\.id), ["x", "youtube", "naver-news", "wikipedia", "github", "bbc", "threads", "reuters"])
        XCTAssertEqual(sites.sites[2].name, "네이버 뉴스")
        XCTAssertEqual(sites.sites.filter(\.preview).map(\.id), ["x", "youtube", "naver-news", "wikipedia", "github", "bbc"])
        XCTAssertEqual(sites.linkHosts.count, 6 + 4 + 3 + 4 + 2 + 4 + 4 + 2)
        // 링크 = 모든 사이트 합집합(링크만 사이트 포함), 카드 = preview 사이트만.
        for host in ["x.com", "youtu.be", "n.news.naver.com", "en.m.wikipedia.org", "github.com", "www.bbc.co.uk", "www.threads.net", "threads.com", "reuters.com"] {
            XCTAssertTrue(sites.linkHosts.contains(host), host)
        }
        for host in ["threads.net", "www.threads.com", "reuters.com", "www.reuters.com"] {
            XCTAssertFalse(sites.isPreviewHost(host), host)
        }
        for host in ["www.youtube.com", "M.YouTube.com", "news.naver.com", "ko.wikipedia.org", "www.github.com", "bbc.com", "mobile.twitter.com"] {
            XCTAssertTrue(sites.isPreviewHost(host), host)
        }
        XCTAssertFalse(sites.linkHosts.contains("instagram.com"), "인스타그램은 서비스 봇 전용(앱이 더한다)")
        XCTAssertEqual(sites.site(forHost: "WWW.Reuters.com")?.id, "reuters")
        XCTAssertEqual(sites.site(forHost: "youtu.be")?.name, "YouTube")
        XCTAssertNil(sites.site(forHost: "example.com"))
    }

    func testUnknownKeysAreIgnoredAndNameIsTrimmed() throws {
        let sites = try decode(#"{"version":2,"extra":1,"sites":[{"id":"x","name":"  X  ","hosts":["x.com"],"preview":true,"ua":"Twitterbot/1.0"}]}"#)
        XCTAssertEqual(sites.sites, [PreviewSite(id: "x", name: "X", hosts: ["x.com"], preview: true)])
    }

    // MARK: - 디코드 (나쁜 응답 → 던짐 → 앱은 폴백)

    func testWrongVersionOrShapeThrows() {
        for bad in [
            #"{"version":1,"sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true}]}"#,
            #"{"version":3,"sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true}]}"#,
            #"{"version":"2","sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true}]}"#,
            #"{"sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true}]}"#,
            #"{"version":2}"#,
            #"{"version":2,"sites":{"id":"x"}}"#,
            #"{"version":2,"sites":[]}"#,
            #"[]"#,
            "<html>Sign in</html>",
        ] {
            XCTAssertThrowsError(try decode(bad), bad) { error in
                guard case .decoding? = error as? RelayError else { return XCTFail("\(bad): \(error)") }
            }
        }
    }

    // MARK: - 디코드 (틀린 항목만 버린다)

    func testMalformedEntriesAreIgnored() throws {
        let good = entry("x", #"["x.com"]"#)
        let malformed = [
            #"{"name":"N","hosts":["a.com"],"preview":true}"#,                     // id 없음
            #"{"id":"a","hosts":["a.com"],"preview":true}"#,                       // name 없음
            #"{"id":"a","name":"N","preview":true}"#,                              // hosts 없음
            #"{"id":"a","name":"N","hosts":["a.com"]}"#,                           // preview 없음
            entry("a", #"["a.com"]"#, preview: #""true""#),                        // preview 문자열
            entry("a", #""a.com""#),                                               // hosts 가 배열 아님
            entry("a", #"[1]"#),                                                   // host 가 문자열 아님
            entry("a", #"[]"#),                                                    // 빈 hosts
            entry("a", #"["a.com"]"#, name: #""   ""#),                            // 빈 이름
            entry("a", #"["a.com"]"#, name: "null"),
            entry("", #"["a.com"]"#),                                              // 빈 id
            entry("A B", #"["a.com"]"#),                                           // id 형식
            entry("a", #"["A.com"]"#),                                             // 대문자
            entry("a", #"["a.com","Evil.com"]"#),                                  // 하나라도 틀리면 항목째
            entry("a", #"["a.com:443"]"#),                                         // 포트
            entry("a", #"["user@a.com"]"#),                                        // 사용자 정보
            entry("a", #"["https://a.com"]"#),                                     // 스킴
            entry("a", #"["a.com/path"]"#),
            entry("a", #"["*.a.com"]"#),
            entry("a", #"["a.com."]"#),
            entry("a", #"["localhost"]"#),                                         // 라벨 하나
            entry("a", #"["127.0.0.1"]"#),                                         // IP
            entry("a", #"["-a.com"]"#),
            entry("a", #"["a..com"]"#),
            entry("a", #"[" a.com"]"#),
            #"5"#, #""x""#, #"[]"#, #"null"#,
        ]
        for bad in malformed {
            let sites = try decode(body([bad, good]))
            XCTAssertEqual(sites.sites.map(\.id), ["x"], bad)
            let after = try decode(body([good, bad]))
            XCTAssertEqual(after.sites.map(\.id), ["x"], bad)
        }
        let all = try decode(body(malformed + [good] + malformed))
        XCTAssertEqual(all.sites.map(\.id), ["x"])
        XCTAssertThrowsError(try decode(body(malformed)), "유효 항목이 하나도 없으면 실패 → 폴백")
    }

    func testDuplicateIDsKeepTheFirst() throws {
        let sites = try decode(body([entry("x", #"["x.com"]"#, preview: "true"), entry("x", #"["evil.example"]"#, preview: "false")]))
        XCTAssertEqual(sites.sites, [PreviewSite(id: "x", name: "N", hosts: ["x.com"], preview: true)])
        XCTAssertFalse(sites.linkHosts.contains("evil.example"))
    }

    func testPlainHostRule() {
        for good in ["x.com", "youtu.be", "ko.m.wikipedia.org", "www.bbc.co.uk", "a-b.c0.example", "1.example.com", "xn--3e0b707e.kr"] {
            XCTAssertTrue(PreviewSites.isPlainHost(good), good)
        }
        for bad in ["", "com", "X.com", "x.com.", ".x.com", "x..com", "-x.com", "x-.com", "x.com:443", "u@x.com", "x_y.com",
                    "1.2.3.4", "*.x.com", "x.com/", "[::1]", "한국.kr", String(repeating: "a", count: 64) + ".com"] {
            XCTAssertFalse(PreviewSites.isPlainHost(bad), bad)
        }
    }

    // MARK: - 폴백 (= v1)

    func testFallbackIsV1XOnly() {
        let fallback = PreviewSites.fallback
        XCTAssertTrue(fallback.isFallback)
        XCTAssertEqual(fallback.sites.map(\.id), ["x"])
        XCTAssertEqual(fallback.linkHosts, PreviewSites.xHosts)
        XCTAssertEqual(fallback.previewHosts, PreviewSites.xHosts)
        XCTAssertEqual(PreviewSites.xHosts, ["x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"])
        XCTAssertFalse(fallback.linkHosts.contains("youtube.com"))
        XCTAssertNotEqual(fallback, PreviewSites(sites: fallback.sites), "받은 목록이 x 하나여도 폴백과 구별(카드 규칙이 다르다)")
    }

    // MARK: - 요청 (같은 인증 헤더)

    func testSitesRequestCarriesSameAuth() throws {
        let bearer = try transport(.bearer("jwt-x")).previewSitesRequest()
        XCTAssertEqual(bearer.httpMethod, "GET")
        XCTAssertEqual(bearer.url?.absoluteString, "https://relay.example.com/v2/preview/sites")
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"), "jwt-x")
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(bearer.httpBody)
        let cookie = try transport(.accessCookie("jwt-c")).previewSitesRequest()
        XCTAssertEqual(cookie.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=jwt-c")
        XCTAssertNil(cookie.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"))
        let based = try transport(.bearer("t"), base: URL(string: "https://example.com/relay/")!).previewSitesRequest()
        XCTAssertEqual(based.url?.absoluteString, "https://example.com/relay/v2/preview/sites")
    }

    func testRouteMissingMapsTo404() {
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 404, data: Data("404 page not found\n".utf8)),
                       .refused(code: "http_404", status: 404), "옛 릴레이·-link-preview off")
    }

    /// 사이트 목록을 구현하지 않은 전송(옛 테스트 대역)은 프로토콜 기본 구현이 404 — 앱은 폴백.
    func testTransportWithoutSitesDefaultsTo404() async {
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
        await XCTAssertThrowsErrorAsync(try await Legacy().previewSites()) {
            XCTAssertEqual($0 as? RelayError, .refused(code: "not_found", status: 404))
        }
    }
}
