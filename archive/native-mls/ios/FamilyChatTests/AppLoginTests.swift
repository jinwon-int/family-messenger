// §12-C A 로그인 핸드오프의 순수 로직(AppLogin.swift) — 로그인 URL · state 난수 · 콜백 해석. 브라우저 시트 자체는 실기기 검증.
import XCTest
import FamilyMLSCore
@testable import FamilyChat

final class AppLoginTests: XCTestCase {
    private let state = String(repeating: "Ab-_9", count: 8)   // 40자 base64url
    private let jwt = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJhbGljZSJ9.c2ln-_X"

    // MARK: 로그인 URL

    func testLoginURLAppendsRouteAndState() {
        let url = AppLogin.loginURL(relayURL: URL(string: "https://relay.example.org")!, state: state)
        XCTAssertEqual(url?.absoluteString, "https://relay.example.org/v2/app-login?state=\(state)")
    }

    func testLoginURLKeepsPathPrefixAndCollapsesTrailingSlash() {
        XCTAssertEqual(AppLogin.loginURL(relayURL: URL(string: "https://relay.example.org/")!, state: state)?.absoluteString,
                       "https://relay.example.org/v2/app-login?state=\(state)")
        XCTAssertEqual(AppLogin.loginURL(relayURL: URL(string: "https://relay.example.org/base/")!, state: state)?.absoluteString,
                       "https://relay.example.org/base/v2/app-login?state=\(state)")
        // 릴레이 주소에 붙어 있던 query·fragment 는 버린다.
        XCTAssertEqual(AppLogin.loginURL(relayURL: URL(string: "https://relay.example.org/?x=1#f")!, state: state)?.absoluteString,
                       "https://relay.example.org/v2/app-login?state=\(state)")
    }

    // MARK: state

    func testStateIsBase64URLWithinRelayBounds() {
        let a = AppLogin.makeState(), b = AppLogin.makeState()
        XCTAssertEqual(a.count, 43, "32 bytes → 43 chars without padding")
        XCTAssertNotEqual(a, b)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(a.unicodeScalars.allSatisfy(allowed.contains), a)
        XCTAssertTrue((16...128).contains(a.count))
    }

    // MARK: 콜백 해석

    private func callback(_ fragment: String?, scheme: String = "hande", host: String = "auth", query: String? = nil) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.percentEncodedQuery = query
        c.percentEncodedFragment = fragment
        return c.url!
    }

    func testValidCallbackYieldsToken() throws {
        XCTAssertEqual(try AppLogin.token(fromCallback: callback("jwt=\(jwt)&state=\(state)"), expectedState: state), jwt)
        // 순서가 바뀌어도, 스킴·호스트 대소문자가 달라도 같다.
        XCTAssertEqual(try AppLogin.token(fromCallback: callback("state=\(state)&jwt=\(jwt)", scheme: "HANDE", host: "Auth"), expectedState: state), jwt)
    }

    func testStateMismatchIsRefused() {
        let url = callback("jwt=\(jwt)&state=\(state)")
        XCTAssertThrowsError(try AppLogin.token(fromCallback: url, expectedState: String(repeating: "x", count: 40))) {
            XCTAssertEqual($0 as? AppLogin.Failure, .stateMismatch)
        }
        XCTAssertThrowsError(try AppLogin.token(fromCallback: callback("jwt=\(jwt)"), expectedState: state)) {
            XCTAssertEqual($0 as? AppLogin.Failure, .stateMismatch, "missing state")
        }
        XCTAssertThrowsError(try AppLogin.token(fromCallback: callback("jwt=\(jwt)&state="), expectedState: "")) {
            XCTAssertEqual($0 as? AppLogin.Failure, .stateMismatch, "an empty expected state never matches")
        }
    }

    func testWrongCallbackIsRefused() {
        for url in [callback("jwt=\(jwt)&state=\(state)", scheme: "https"),
                    callback("jwt=\(jwt)&state=\(state)", host: "other")] {
            XCTAssertThrowsError(try AppLogin.token(fromCallback: url, expectedState: state)) {
                XCTAssertEqual($0 as? AppLogin.Failure, .notCallback, url.absoluteString)
            }
        }
    }

    func testFragmentOnlyNeverQuery() {
        // 릴레이는 fragment 로만 준다 — query 에 실린 값은 읽지 않는다(서버 로그·리퍼러로 새는 경로를 열지 않기 위해).
        let url = callback(nil, query: "jwt=\(jwt)&state=\(state)")
        XCTAssertThrowsError(try AppLogin.token(fromCallback: url, expectedState: state)) {
            XCTAssertEqual($0 as? AppLogin.Failure, .stateMismatch)
        }
    }

    func testMissingOrMalformedTokenIsRefused() {
        XCTAssertThrowsError(try AppLogin.token(fromCallback: callback("state=\(state)"), expectedState: state)) {
            XCTAssertEqual($0 as? AppLogin.Failure, .missingToken)
        }
        XCTAssertThrowsError(try AppLogin.token(fromCallback: callback("jwt=&state=\(state)"), expectedState: state)) {
            XCTAssertEqual($0 as? AppLogin.Failure, .missingToken)
        }
        for bad in ["opaque", "a.b", "a.b.c.d", "a..c", "a.b!.c", "a.b.c%20"] {
            XCTAssertThrowsError(try AppLogin.token(fromCallback: callback("jwt=\(bad)&state=\(state)"), expectedState: state)) {
                XCTAssertEqual($0 as? AppLogin.Failure, .malformedToken, bad)
            }
        }
    }

    func testJWTShape() {
        XCTAssertTrue(AppLogin.isJWTShaped(jwt))
        XCTAssertFalse(AppLogin.isJWTShaped(""))
        XCTAssertFalse(AppLogin.isJWTShaped("a.b"))
        XCTAssertFalse(AppLogin.isJWTShaped("a.b.c=="), "padding is not base64url")
        XCTAssertFalse(AppLogin.isJWTShaped("a.b.ü"))
    }

    // MARK: 모델 연결

    @MainActor
    func testRelayURLComesFromDependencies() {
        var deps = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: InMemoryStateStore(), messageStore: InMemoryMessageStore(),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "owner-iphone-abc123" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in nil })
        XCTAssertNil(AppModel(dependencies: deps).relayURL, "default: not configured")
        deps.relayURL = URL(string: "https://relay.example.org")
        XCTAssertEqual(AppModel(dependencies: deps).relayURL?.host, "relay.example.org")
    }
}
