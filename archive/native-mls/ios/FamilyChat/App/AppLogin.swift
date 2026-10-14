// §12-C A — 가족 로그인(시스템 브라우저 시트). 앱은 비밀번호도 쿠키도 직접 다루지 않는다:
//   1. 앱이 난수 `state` 를 만들고 `ASWebAuthenticationSession` 으로 릴레이 `GET /v2/app-login?state=…` 를 연다
//      (Safari 시트 — Google 은 앱 내 WKWebView 로그인을 막지만 이 시트는 허용한다).
//   2. 엣지(Cloudflare Access)가 평소대로 Google 로그인을 처리하고 `Cf-Access-Jwt-Assertion` 을 주입한다.
//   3. 릴레이(server/applogin.go)가 그 토큰을 검증한 뒤 **고정 스킴** `hande://auth#jwt=…&state=…` 로 302 — 세션이 가로채
//      앱에 돌려준다(fragment 라 서버 로그에 남지 않고, 다른 앱은 이 세션의 콜백을 받을 수 없다).
//   4. 앱은 `state` 가 자기 것인지 확인하고 JWT 를 `RelayCredential.accessCookie` 로 쓴다 — 붙여넣기 흐름과 같은 토큰·같은 권한.
// 순수 로직(`AppLogin`)과 UI 세션(`AccessLoginSession`)을 나눈다: 전자는 시뮬레이터 테스트(AppLoginTests)로 고정한다.
// 이 파일은 앱 타깃 전용이다(NSE 소스 목록에 넣지 말 것 — AuthenticationServices·UIKit).
import Foundation
import FamilyMLSCore
#if canImport(AuthenticationServices) && canImport(UIKit)
import AuthenticationServices
import UIKit
#endif

enum AppLogin {
    /// 릴레이 `appLoginCallback` 과 같아야 한다(`hande://auth`). project.yml CFBundleURLTypes 에도 같은 스킴.
    static let callbackScheme = "hande"
    static let callbackHost = "auth"
    static let path = "/v2/app-login"

    enum Failure: Error, Equatable {
        /// 릴레이 주소에서 로그인 URL 을 만들 수 없다.
        case badRelayURL
        /// 로그인 창을 열 수 없다(세션 start 실패).
        case cannotStart
        /// 콜백이 `hande://auth` 가 아니다.
        case notCallback
        /// 콜백의 state 가 이 요청의 것이 아니다(없음 포함).
        case stateMismatch
        /// 콜백에 jwt 가 없다(릴레이가 앱 로그인을 지원하지 않거나 응답이 비었다).
        case missingToken
        /// jwt 가 `a.b.c` 꼴이 아니다.
        case malformedToken
    }

    /// 32 바이트 난수 → base64url 43자(패딩 없음). 릴레이는 16..128 base64url 만 받는다.
    static func makeState() -> String {
        var generator = SystemRandomNumberGenerator()   // Apple 플랫폼에서 암호학적 난수
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// `<relay>/v2/app-login?state=<state>` — 릴레이 주소의 끝 `/` 와 경로 접두는 `URLSessionRelayTransport.makeRequest` 와 같은 규칙.
    static func loginURL(relayURL: URL, state: String) -> URL? {
        guard var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false) else { return nil }
        var basePath = components.percentEncodedPath
        if basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + path
        components.queryItems = [URLQueryItem(name: "state", value: state)]
        components.fragment = nil
        return components.url
    }

    /// 콜백 `hande://auth#jwt=…&state=…` 에서 JWT 를 꺼낸다. fragment 만 읽는다(query 의 값은 무시 — 릴레이는 fragment 로만 준다).
    static func token(fromCallback url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == callbackScheme, components.host?.lowercased() == callbackHost else {
            throw Failure.notCallback
        }
        let fields = formFields(components.percentEncodedFragment ?? "")
        guard let state = fields["state"], !expectedState.isEmpty, state == expectedState else { throw Failure.stateMismatch }
        guard let jwt = fields["jwt"], !jwt.isEmpty else { throw Failure.missingToken }
        guard isJWTShaped(jwt) else { throw Failure.malformedToken }
        return jwt
    }

    /// `k=v&k2=v2`(percent-encoded) → 사전. 같은 키가 또 오면 첫 값을 지킨다. URLComponents 의 `percentEncodedQuery` 세터는
    /// 허용되지 않는 문자에 fatal 이라 쓰지 않는다 — 콜백은 외부 입력이다.
    static func formFields(_ encoded: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in encoded.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = String(parts[0]).removingPercentEncoding, !key.isEmpty else { continue }
            let value = parts.count == 2 ? (String(parts[1]).removingPercentEncoding ?? "") : ""
            if fields[key] == nil { fields[key] = value }
        }
        return fields
    }

    /// `header.payload.signature` — 세 조각 모두 비어 있지 않은 base64url. 서명 검증은 하지 않는다(엣지·릴레이의 몫).
    static func isJWTShaped(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }
}

extension Strings {
    /// 로그인 실패 사유를 사람이 읽을 문구로. 사용자가 시트를 닫은 경우는 호출자가 먼저 걸러 조용히 넘긴다.
    static func loginFailure(_ error: Error) -> String {
        switch error {
        case AppLogin.Failure.badRelayURL: return relayNotConfigured
        case AppLogin.Failure.cannotStart: return loginFailed("로그인 창을 열 수 없습니다. 앱을 다시 열어 시도해 주세요.")
        case AppLogin.Failure.notCallback: return loginFailed("릴레이의 응답 주소가 예상과 다릅니다.")
        case AppLogin.Failure.stateMismatch: return loginFailed("이 요청의 응답이 아닙니다(state 불일치). 다시 시도해 주세요.")
        case AppLogin.Failure.missingToken: return loginFailed("릴레이가 세션을 돌려주지 않았습니다(릴레이가 아직 앱 로그인을 지원하지 않을 수 있습니다).")
        case AppLogin.Failure.malformedToken: return loginFailed("세션 형식이 올바르지 않습니다.")
        default: return loginFailed("\(error.localizedDescription)")
        }
    }
}

#if canImport(AuthenticationServices) && canImport(UIKit)
/// 시스템 브라우저 시트로 릴레이 로그인 URL 을 열고 콜백의 JWT 를 자격증명으로 돌려준다. 한 번에 한 세션.
final class AccessLoginSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?

    /// 사용자가 시트를 닫으면 `ASWebAuthenticationSessionError.canceledLogin` 을 던진다 — 호출자는 조용히 넘긴다.
    @MainActor
    func run(relayURL: URL) async throws -> RelayCredential {
        let state = AppLogin.makeState()
        guard let url = AppLogin.loginURL(relayURL: relayURL, state: state) else { throw AppLogin.Failure.badRelayURL }
        anchor = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        defer { session = nil }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: AppLogin.callbackScheme) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AppLogin.Failure.missingToken)
                }
            }
            session.presentationContextProvider = self
            // Safari 의 Google·Access 세션을 함께 쓴다: 세션이 만료돼 다시 로그인할 때 대개 한 번의 탭으로 끝난다.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AppLogin.Failure.cannotStart)
            }
        }
        return .accessCookie(try AppLogin.token(fromCallback: callback, expectedState: state))
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
#endif
