// `AccessJWT.subject(of:)` — 등록 JSON 의 subject 를 채우는 `sub` 읽기(검증 아님).
import XCTest
@testable import FamilyMLSCore

final class AccessSubjectTests: XCTestCase {
    private func base64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func jwt(payload: String) -> String {
        base64url("{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"k\"}") + "." + base64url(payload) + ".c2ln"
    }

    func testAccessCookieSubjectIsRead() {
        let token = jwt(payload: "{\"aud\":[\"a\"],\"email\":\"owner@example.com\",\"sub\":\"7c1f3e0a-sub\",\"iat\":1}")
        XCTAssertEqual(RelayCredential.accessCookie(token).accessSubject, "7c1f3e0a-sub")
        XCTAssertEqual(RelayCredential.bearer(token).accessSubject, "7c1f3e0a-sub")
    }

    func testServiceTokenWithEmptySubjectIsNil() {
        // CF Access 서비스 토큰 JWT 는 `sub` 가 빈 문자열(#243 1절 실측) — 운영자가 채우도록 nil.
        XCTAssertNil(RelayCredential.bearer(jwt(payload: "{\"sub\":\"\",\"common_name\":\"bot\"}")).accessSubject)
        XCTAssertNil(AccessJWT.subject(of: jwt(payload: "{\"common_name\":\"bot\"}")))
    }

    func testNonJWTValuesAreNil() {
        XCTAssertNil(AccessJWT.subject(of: ""))
        XCTAssertNil(AccessJWT.subject(of: "opaque-token"))
        XCTAssertNil(AccessJWT.subject(of: "a.b"))
        XCTAssertNil(AccessJWT.subject(of: "a.!!!.c"))
        XCTAssertNil(AccessJWT.subject(of: "a." + base64url("[1,2]") + ".c"), "payload must be an object")
        XCTAssertNil(AccessJWT.subject(of: "a." + base64url("{\"sub\":42}") + ".c"), "sub must be a string")
    }

    func testBase64URLPaddingVariants() {
        // payload 길이에 따라 base64 나머지 0·2·3 이 모두 나오도록 subject 길이를 바꿔 본다.
        for n in 1...12 {
            let sub = String(repeating: "s", count: n)
            XCTAssertEqual(AccessJWT.subject(of: jwt(payload: "{\"sub\":\"\(sub)\"}")), sub, "n=\(n)")
        }
        XCTAssertNil(AccessJWT.base64URLDecode("A"), "length ≡ 1 (mod 4) is never valid base64")
    }

    func testSurroundingWhitespaceIsIgnored() {
        let token = jwt(payload: "{\"sub\":\"paste\"}")
        XCTAssertEqual(AccessJWT.subject(of: "  \(token)\n"), "paste")
    }
}
