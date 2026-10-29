// 서버 탐색(#584 PR 2) — 입력 정규화·후보 순서·문서 파싱·버전 비교·탐색 흐름(가짜 fetch 표). 네트워크 없음(Linux).
import XCTest
@testable import FamilyMLSCore

final class ServerDiscoveryTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: 입력 정규화

    func testNormalizeAddsHTTPSAndStripsTrailingSlashQueryFragment() {
        XCTAssertEqual(ServerDiscovery.normalize("example.com"), .success(url("https://example.com")))
        XCTAssertEqual(ServerDiscovery.normalize("  Example.COM/  "), .success(url("https://example.com")))
        XCTAssertEqual(ServerDiscovery.normalize("https://example.com/relay/"), .success(url("https://example.com/relay")))
        XCTAssertEqual(ServerDiscovery.normalize("https://example.com:8443/?x=1#f"), .success(url("https://example.com:8443")))
        XCTAssertEqual(ServerDiscovery.normalize("HTTPS://Relay.Example.com"), .success(url("https://relay.example.com")))
    }

    func testNormalizeRejectsEmptyMalformedCredentialsAndPlainHTTP() {
        XCTAssertEqual(ServerDiscovery.normalize(""), .failure(.invalidInput))
        XCTAssertEqual(ServerDiscovery.normalize("   "), .failure(.invalidInput))
        XCTAssertEqual(ServerDiscovery.normalize("https://"), .failure(.invalidInput))
        XCTAssertEqual(ServerDiscovery.normalize("ftp://example.com"), .failure(.invalidInput))
        XCTAssertEqual(ServerDiscovery.normalize("https://user:pw@example.com"), .failure(.invalidInput))
        XCTAssertEqual(ServerDiscovery.normalize("http://example.com"), .failure(.insecure(host: "example.com")))
        // 루프백만 http 허용(격리 스모크·개발)
        XCTAssertEqual(ServerDiscovery.normalize("http://localhost:8080"), .success(url("http://localhost:8080")))
        XCTAssertEqual(ServerDiscovery.normalize("http://127.0.0.1:8080/"), .success(url("http://127.0.0.1:8080")))
    }

    // MARK: 후보 순서

    func testWellKnownCandidateOrder() {
        XCTAssertEqual(ServerDiscovery.wellKnownCandidates(for: url("https://example.com")),
                       [url("https://example.com/.well-known/hande"), url("https://hande.example.com/.well-known/hande")])
        // 입력 경로는 버리고 포트는 지킨다
        XCTAssertEqual(ServerDiscovery.wellKnownCandidates(for: url("https://example.com:8443/relay")),
                       [url("https://example.com:8443/.well-known/hande"), url("https://hande.example.com:8443/.well-known/hande")])
        // 이미 hande. 로 시작 → 두 번째 후보 없음
        XCTAssertEqual(ServerDiscovery.wellKnownCandidates(for: url("https://hande.example.com")),
                       [url("https://hande.example.com/.well-known/hande")])
        // 루프백·IP 리터럴은 하위 도메인이 없다
        XCTAssertEqual(ServerDiscovery.wellKnownCandidates(for: url("http://localhost:8080")), [url("http://localhost:8080/.well-known/hande")])
        XCTAssertEqual(ServerDiscovery.wellKnownCandidates(for: url("https://10.0.0.2")), [url("https://10.0.0.2/.well-known/hande")])
    }

    func testEndpointJoinsBasePath() {
        XCTAssertEqual(ServerDiscovery.endpoint(url("https://example.com"), path: "/v2/health"), url("https://example.com/v2/health"))
        XCTAssertEqual(ServerDiscovery.endpoint(url("https://example.com/relay/"), path: "/v2/health"), url("https://example.com/relay/v2/health"))
    }

    // MARK: 문서 파싱

    private let fullDocument = """
    {"version":1,"relay":{"base_url":"https://relay.example.com","app_login":"/v2/app-login"},
     "hande":{"web_url":"https://hande.example.com"},"name":"  우리 집  ","min_app":{"ios":"0.1.0","android":"0.1.0"}}
    """

    func testParseFullDocument() throws {
        let doc = try XCTUnwrap(try? ServerDiscovery.parseDocument(Data(fullDocument.utf8)).get())
        XCTAssertEqual(doc.baseURL, url("https://relay.example.com"))
        XCTAssertEqual(doc.appLoginPath, "/v2/app-login")
        XCTAssertEqual(doc.webURL, url("https://hande.example.com"))
        XCTAssertEqual(doc.name, "우리 집", "trimmed")
        XCTAssertEqual(doc.minAppIOS, "0.1.0")
    }

    func testParseMinimalDocumentUsesDefaults() throws {
        let doc = try XCTUnwrap(try? ServerDiscovery.parseDocument(Data(#"{"version":1,"relay":{"base_url":"https://r.example.com"}}"#.utf8)).get())
        XCTAssertEqual(doc.appLoginPath, "/v2/app-login")
        XCTAssertNil(doc.webURL); XCTAssertNil(doc.name); XCTAssertNil(doc.minAppIOS)
    }

    func testParseRejectsBadDocuments() {
        func failure(_ json: String) -> ServerDiscovery.DocumentError? {
            if case .failure(let e) = ServerDiscovery.parseDocument(Data(json.utf8)) { return e }
            return nil
        }
        XCTAssertEqual(failure("not json"), .notJSONObject)
        XCTAssertEqual(failure("[1]"), .notJSONObject)
        XCTAssertEqual(failure(#"{"relay":{"base_url":"https://r.example.com"}}"#), .unsupportedVersion)
        XCTAssertEqual(failure(#"{"version":2,"relay":{"base_url":"https://r.example.com"}}"#), .unsupportedVersion)
        XCTAssertEqual(failure(#"{"version":1}"#), .missingBaseURL)
        XCTAssertEqual(failure(#"{"version":1,"relay":{"base_url":""}}"#), .missingBaseURL)
        XCTAssertEqual(failure(#"{"version":1,"relay":{"base_url":"http://r.example.com"}}"#), .badBaseURL, "plain http refused")
        XCTAssertEqual(failure(#"{"version":1,"relay":{"base_url":"https://r.example.com/"}}"#), .badBaseURL, "trailing slash is not normalised — rejected")
        XCTAssertEqual(failure(#"{"version":1,"relay":{"base_url":"https://r.example.com?x=1"}}"#), .badBaseURL)
        XCTAssertEqual(failure(#"{"version":1,"relay":{"base_url":"https://r.example.com","app_login":"v2/app-login"}}"#), .badAppLogin)
        XCTAssertEqual(failure(#"{"version":1,"relay":{"base_url":"https://r.example.com"},"hande":{"web_url":"ftp://x"}}"#), .badWebURL)
        // 루프백 http 문서는 허용(격리 스모크)
        XCTAssertNil(failure(#"{"version":1,"relay":{"base_url":"http://127.0.0.1:9000"}}"#))
    }

    func testParseNameIsCapped() throws {
        let long = String(repeating: "가", count: 100)
        let doc = try XCTUnwrap(try? ServerDiscovery.parseDocument(Data(#"{"version":1,"relay":{"base_url":"https://r.example.com"},"name":"\#(long)"}"#.utf8)).get())
        XCTAssertEqual(doc.name?.count, ServerDiscovery.maxNameLength)
    }

    func testParseHealth() {
        XCTAssertTrue(ServerDiscovery.parseHealth(Data(#"{"ok":true}"#.utf8)))
        XCTAssertFalse(ServerDiscovery.parseHealth(Data(#"{"ok":false}"#.utf8)))
        XCTAssertFalse(ServerDiscovery.parseHealth(Data("ok".utf8)))
    }

    // MARK: 버전 비교

    func testAppVersionCompare() {
        XCTAssertTrue(AppVersion("0.1.0")! < AppVersion("0.2")!)
        XCTAssertTrue(AppVersion("1.0")! == AppVersion("1.0.0")!)
        XCTAssertTrue(AppVersion("1.0.1")! > AppVersion("1.0")!)
        XCTAssertTrue(AppVersion("1.10")! > AppVersion("1.9.9")!)
        XCTAssertNil(AppVersion("1.0-beta")); XCTAssertNil(AppVersion("")); XCTAssertNil(AppVersion("1..0")); XCTAssertNil(AppVersion("a.b"))
        XCTAssertTrue(ServerDiscovery.isTooOld(current: "0.1.0", minimum: "0.2.0"))
        XCTAssertFalse(ServerDiscovery.isTooOld(current: "0.2.0", minimum: "0.2.0"))
        XCTAssertFalse(ServerDiscovery.isTooOld(current: "0.1.0", minimum: nil))
        XCTAssertFalse(ServerDiscovery.isTooOld(current: "0.1.0", minimum: "garbage"), "unreadable requirement never blocks")
    }

    // MARK: 딥링크

    func testServerLink() {
        XCTAssertEqual(ServerDiscovery.serverLink("hande://server?url=https%3A%2F%2Fexample.com"), "https://example.com")
        XCTAssertEqual(ServerDiscovery.serverLink(" hande://server?url=example.com "), "example.com")
        XCTAssertNil(ServerDiscovery.serverLink("hande://auth#jwt=x"))
        XCTAssertNil(ServerDiscovery.serverLink("hande://server?url="))
        XCTAssertNil(ServerDiscovery.serverLink("example.com"))
    }

    // MARK: 탐색 흐름(가짜 fetch 표)

    private struct Table {
        var replies: [String: (Int, String)] = [:]
        var failing: Set<String> = []
        private(set) var calls: [String] = []
        mutating func record(_ url: URL) { calls.append(url.absoluteString) }
    }

    private final class Box { var table = Table(); init(_ t: Table) { table = t } }
    private struct Offline: Error {}

    private func discoverer(_ table: Table, version: String = "0.1.0") -> (ServerDiscoverer, Box) {
        let box = Box(table)
        let d = ServerDiscoverer(fetch: { url in
            box.table.record(url)
            let key = url.absoluteString
            if box.table.failing.contains(key) { throw Offline() }
            guard let reply = box.table.replies[key] else { return (404, Data()) }
            return (reply.0, Data(reply.1.utf8))
        }, appVersion: version)
        return (d, box)
    }

    func testDiscoverViaWellKnownOnHost() async {
        var t = Table()
        t.replies["https://example.com/.well-known/hande"] = (200, fullDocument)
        t.replies["https://relay.example.com/v2/health"] = (200, #"{"ok":true}"#)
        let (d, box) = discoverer(t)
        let result = await d.discover("example.com")
        XCTAssertEqual(result, .success(ServerInfo(baseURL: url("https://relay.example.com"), name: "우리 집", appLoginPath: "/v2/app-login",
                                                   webURL: url("https://hande.example.com"), discoveredVia: .wellKnown, minAppIOS: "0.1.0")))
        XCTAssertEqual(box.table.calls, ["https://example.com/.well-known/hande", "https://relay.example.com/v2/health"], "first candidate hit — no second probe")
    }

    func testDiscoverFallsThroughToHandeSubdomainThenDirect() async {
        var t = Table()
        t.failing.insert("https://example.com/.well-known/hande")   // 네트워크 오류는 다음 후보로
        t.replies["https://hande.example.com/.well-known/hande"] = (200, #"{"version":1,"relay":{"base_url":"https://r.example.com"},"name":"집"}"#)
        t.replies["https://r.example.com/v2/health"] = (200, #"{"ok":true}"#)
        let (d, box) = discoverer(t)
        let result = await d.discover("https://example.com/")
        XCTAssertEqual(try? result.get().baseURL, url("https://r.example.com"))
        XCTAssertEqual(try? result.get().discoveredVia, .wellKnown)
        XCTAssertEqual(box.table.calls.count, 3)

        // 문서가 어디에도 없으면 입력값 자체가 릴레이
        var direct = Table()
        direct.replies["https://example.com/v2/health"] = (200, #"{"ok":true}"#)
        let (d2, box2) = discoverer(direct)
        let r2 = await d2.discover("example.com")
        XCTAssertEqual(r2, .success(ServerInfo(baseURL: url("https://example.com"), discoveredVia: .direct)))
        XCTAssertEqual(box2.table.calls.last, "https://example.com/v2/health")
    }

    func testMalformedDocumentIsSkippedNotFatal() async {
        var t = Table()
        t.replies["https://example.com/.well-known/hande"] = (200, "<html>")   // 캡티브 포털·엉뚱한 사이트
        t.replies["https://example.com/v2/health"] = (200, #"{"ok":true}"#)
        let (d, _) = discoverer(t)
        let result = await d.discover("example.com")
        XCTAssertEqual(try? result.get().discoveredVia, .direct)
    }

    func testFailures() async {
        // 아무것도 없음
        let (none, _) = discoverer(Table())
        let nothing = await none.discover("example.com")
        XCTAssertEqual(nothing, .failure(.notFound(host: "example.com")))
        // 직접 주소인데 망 자체가 안 됨
        var off = Table(); off.failing.insert("https://example.com/v2/health")
        let (offline, _) = discoverer(off)
        let down = await offline.discover("example.com")
        if case .failure(.network) = down {} else { XCTFail("expected network failure, got \(down)") }
        // 문서는 있는데 그 릴레이의 health 가 죽음
        var sick = Table()
        sick.replies["https://example.com/.well-known/hande"] = (200, #"{"version":1,"relay":{"base_url":"https://r.example.com"}}"#)
        sick.replies["https://r.example.com/v2/health"] = (503, "")
        let (unhealthy, _) = discoverer(sick)
        let sickResult = await unhealthy.discover("example.com")
        XCTAssertEqual(sickResult, .failure(.healthFailed(baseURL: url("https://r.example.com"), detail: "http_503")))
        // health 본문이 ok 가 아님(직접) → notFound
        var notOK = Table(); notOK.replies["https://example.com/v2/health"] = (200, #"{"ok":false}"#)
        let (bad, _) = discoverer(notOK)
        let badResult = await bad.discover("example.com")
        XCTAssertEqual(badResult, .failure(.notFound(host: "example.com")))
        // 입력 오류는 fetch 전에
        let (input, box) = discoverer(Table())
        let insecure = await input.discover("http://example.com")
        XCTAssertEqual(insecure, .failure(.insecure(host: "example.com")))
        let empty = await input.discover("")
        XCTAssertEqual(empty, .failure(.invalidInput))
        XCTAssertTrue(box.table.calls.isEmpty)
    }

    func testTooOldIsDecidedBeforeHealth() async {
        var t = Table()
        t.replies["https://example.com/.well-known/hande"] = (200, #"{"version":1,"relay":{"base_url":"https://r.example.com"},"min_app":{"ios":"0.2.0"}}"#)
        t.replies["https://r.example.com/v2/health"] = (200, #"{"ok":true}"#)
        let (d, box) = discoverer(t, version: "0.1.0")
        let old = await d.discover("example.com")
        XCTAssertEqual(old, .failure(.tooOld(minimum: "0.2.0", current: "0.1.0")))
        XCTAssertEqual(box.table.calls.count, 1, "no health probe for an app the server will refuse")
        let (ok, _) = discoverer(t, version: "0.2.0")
        let fresh = await ok.discover("example.com")
        XCTAssertEqual(try? fresh.get().minAppIOS, "0.2.0")
    }
}
