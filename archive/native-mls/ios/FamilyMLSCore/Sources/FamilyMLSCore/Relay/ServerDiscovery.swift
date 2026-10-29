// 서버 탐색(#584 PR 2, Matrix 홈서버 방식) — 사용자가 적은 도메인·주소에서 릴레이 base URL 을 찾는다(CONTRACTS.md §2.5).
//
//   1. 입력 정규화: 스킴 없으면 https, 끝 `/` 제거, 사용자정보·query·fragment 거부. http 는 localhost·루프백에만 허용.
//   2. `.well-known/hande` 후보를 차례로 GET: `https://<host>/.well-known/hande` → `https://hande.<host>/.well-known/hande`.
//      문서 `{"version":1,"relay":{"base_url":"https://…","app_login":"/v2/app-login"},"hande":{"web_url":"…"},"name":"…","min_app":{"ios":"0.1.0"}}`
//      를 엄격히 읽는다(version 1 · base_url https · 끝 `/` 없음). 문서가 없으면 입력값 자체를 릴레이 base URL 로 본다.
//   3. `GET <base>/v2/health` → `{"ok":true}` 로 확인한 뒤 `ServerInfo` 를 돌려준다. `min_app.ios` 가 앱 버전보다 크면 `.tooOld`.
// 네트워크는 `Fetch` 클로저로 주입한다 — 판정은 전부 순수 함수라 Linux `swift test` 로 고정한다(ServerDiscoveryTests).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 탐색 결과 — 앱이 `hande.server`(App Group)에 저장하는 값의 원천.
public struct ServerInfo: Equatable, Codable {
    public enum Via: String, Codable, Equatable {
        /// `.well-known/hande` 문서로 찾았다.
        case wellKnown
        /// 문서가 없어 입력값을 릴레이 주소로 썼다(`/v2/health` 만 확인).
        case direct
        /// 빌드 설정 `FC_RELAY_URL` 기본값(가족 TestFlight) — 탐색 없이 채택.
        case buildDefault
    }

    public var baseURL: URL
    public var name: String?
    public var appLoginPath: String
    public var webURL: URL?
    public var discoveredVia: Via
    /// 문서의 `min_app.ios`(없으면 nil). 비교는 탐색 단계에서 끝나므로 표시용.
    public var minAppIOS: String?

    public init(baseURL: URL, name: String? = nil, appLoginPath: String = ServerDiscovery.defaultAppLoginPath,
                webURL: URL? = nil, discoveredVia: Via, minAppIOS: String? = nil) {
        self.baseURL = baseURL
        self.name = name
        self.appLoginPath = appLoginPath
        self.webURL = webURL
        self.discoveredVia = discoveredVia
        self.minAppIOS = minAppIOS
    }
}

/// `.well-known/hande` 문서(파싱 결과). 필드 규칙은 `ServerDiscovery.parseDocument`.
public struct WellKnownDocument: Equatable {
    public var baseURL: URL
    public var appLoginPath: String
    public var webURL: URL?
    public var name: String?
    public var minAppIOS: String?
}

/// 마케팅 버전(`CFBundleShortVersionString`) 비교 — 숫자 조각만(`0.1.0`, `1.0`). 빠진 조각은 0. 숫자가 아니면 nil.
public struct AppVersion: Equatable, Comparable {
    public let parts: [Int]

    public init?(_ text: String) {
        let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(piece) else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let n = max(lhs.parts.count, rhs.parts.count)
        for i in 0..<n {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

public enum ServerDiscoveryFailure: Error, Equatable {
    /// 입력이 주소가 아니다(빈 값·파싱 불가·사용자정보 포함).
    case invalidInput
    /// http 는 localhost 에만 — 평문 릴레이 거부.
    case insecure(host: String)
    /// `.well-known` 도 없고 입력 주소의 `/v2/health` 도 응답하지 않는다.
    case notFound(host: String)
    /// 문서는 찾았지만 그 base_url 의 `/v2/health` 가 실패했다.
    case healthFailed(baseURL: URL, detail: String)
    /// 서버가 요구하는 최소 앱 버전보다 이 앱이 낮다.
    case tooOld(minimum: String, current: String)
    /// 네트워크 자체에 닿지 않았다(오프라인 등).
    case network(String)
}

public enum ServerDiscovery {
    public static let wellKnownPath = "/.well-known/hande"
    public static let healthPath = "/v2/health"
    public static let defaultAppLoginPath = "/v2/app-login"
    /// 웹 설정 화면이 노출하는 딥링크 `hande://server?url=<주소>` — 붙여넣기(QR 은 후속).
    public static let linkScheme = "hande"
    public static let linkHost = "server"
    /// 이름 표시 상한(문서가 주는 값은 외부 입력).
    public static let maxNameLength = 64

    // MARK: 입력 정규화 (순수)

    /// 도메인(`example.com`)·주소(`https://example.com/relay/`)를 릴레이 base URL 후보로. 스킴 없음 → https, 끝 `/` 제거,
    /// host 소문자, query·fragment 버림. 사용자정보가 있으면 거부. http 는 localhost·127.0.0.1·::1 만.
    public static func normalize(_ raw: String) -> Result<URL, ServerDiscoveryFailure> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.invalidInput) }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else { return .failure(.invalidInput) }
        guard components.user == nil, components.password == nil else { return .failure(.invalidInput) }
        switch scheme {
        case "https": break
        case "http": if !isLoopback(host) { return .failure(.insecure(host: host)) }
        default: return .failure(.invalidInput)
        }
        components.scheme = scheme
        components.host = host
        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        guard let url = components.url else { return .failure(.invalidInput) }
        return .success(url)
    }

    public static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// `.well-known/hande` 후보(순서 고정): `<host>` → `hande.<host>`. host 가 이미 `hande.` 로 시작하거나 루프백·IP 리터럴이면 첫 번째만.
    /// 입력의 경로는 버린다(문서는 호스트 루트에만). 포트·스킴은 그대로.
    public static func wellKnownCandidates(for base: URL) -> [URL] {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false), let host = components.host else { return [] }
        components.percentEncodedPath = wellKnownPath
        components.query = nil
        components.fragment = nil
        var out: [URL] = []
        if let first = components.url { out.append(first) }
        if !host.hasPrefix("hande."), !isLoopback(host), !isIPLiteral(host) {
            components.host = "hande." + host
            if let second = components.url { out.append(second) }
        }
        return out
    }

    static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }   // IPv6
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// `<base><path>` — base 경로 뒤에 붙인다(`URLSessionRelayTransport.makeRequest` 와 같은 규칙).
    public static func endpoint(_ base: URL, path: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: 문서 파싱 (순수)

    public enum DocumentError: Error, Equatable {
        case notJSONObject
        case unsupportedVersion
        case missingBaseURL
        /// base_url 이 https 가 아니거나(localhost 제외) host 가 없거나 끝 `/`·query·fragment 가 있다.
        case badBaseURL
        case badAppLogin
        case badWebURL
    }

    /// 엄격한 문서 읽기: `version == 1`, `relay.base_url` 은 정규형(https, 끝 `/` 없음 — 정규화하지 않고 거부), `relay.app_login` 은
    /// `/` 로 시작(없으면 `/v2/app-login`), `hande.web_url` 은 https 주소(없으면 nil), `name` 은 다듬어 64자까지, `min_app.ios` 문자열.
    public static func parseDocument(_ data: Data) -> Result<WellKnownDocument, DocumentError> {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.notJSONObject) }
        guard let version = object["version"] as? Int, version == 1 else { return .failure(.unsupportedVersion) }
        guard let relay = object["relay"] as? [String: Any], let rawBase = relay["base_url"] as? String, !rawBase.isEmpty else {
            return .failure(.missingBaseURL)
        }
        guard let baseURL = canonicalHTTPSURL(rawBase) else { return .failure(.badBaseURL) }
        var appLogin = defaultAppLoginPath
        if let raw = relay["app_login"] {
            guard let path = raw as? String, path.hasPrefix("/"), !path.contains("?"), !path.contains("#") else { return .failure(.badAppLogin) }
            appLogin = path
        }
        var webURL: URL?
        if let hande = object["hande"] as? [String: Any], let raw = hande["web_url"] {
            guard let text = raw as? String, let url = canonicalHTTPSURL(text) else { return .failure(.badWebURL) }
            webURL = url
        }
        var name: String?
        if let raw = object["name"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { name = String(trimmed.prefix(maxNameLength)) }
        }
        var minIOS: String?
        if let minApp = object["min_app"] as? [String: Any], let ios = minApp["ios"] as? String, !ios.isEmpty { minIOS = ios }
        return .success(WellKnownDocument(baseURL: baseURL, appLoginPath: appLogin, webURL: webURL, name: name, minAppIOS: minIOS))
    }

    /// 문서 안의 주소 규칙: https(루프백은 http 허용) · host 있음 · 사용자정보·query·fragment 없음 · 끝 `/` 없음(루트 `/` 도 거부).
    static func canonicalHTTPSURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil, !components.percentEncodedPath.hasSuffix("/") else { return nil }
        guard scheme == "https" || (scheme == "http" && isLoopback(host.lowercased())) else { return nil }
        return components.url
    }

    /// `GET /v2/health` 본문 `{"ok":true}`.
    public static func parseHealth(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return object["ok"] as? Bool == true
    }

    /// `min_app.ios` 대 앱 버전. 어느 쪽이든 읽을 수 없으면 막지 않는다(false).
    public static func isTooOld(current: String, minimum: String?) -> Bool {
        guard let minimum, let need = AppVersion(minimum), let have = AppVersion(current) else { return false }
        return have < need
    }

    /// `hande://server?url=<주소>` 딥링크·붙여넣기 → 주소. 그 꼴이 아니면 nil(호출자는 입력을 그대로 쓴다).
    public static func serverLink(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == linkScheme,
              components.host?.lowercased() == linkHost else { return nil }
        guard let value = components.queryItems?.first(where: { $0.name == "url" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// 탐색 실행기 — `fetch` 로 HTTP 를 주입한다(앱은 `urlSessionFetch`, 테스트는 표).
public struct ServerDiscoverer {
    public typealias Fetch = (URL) async throws -> (status: Int, body: Data)

    public var fetch: Fetch
    /// 이 앱의 마케팅 버전(`CFBundleShortVersionString`).
    public var appVersion: String

    public init(fetch: @escaping Fetch, appVersion: String) {
        self.fetch = fetch
        self.appVersion = appVersion
    }

    /// 입력 → `.well-known` 후보 순서대로 → (없으면 직접) → `/v2/health` 확인 → `ServerInfo`.
    public func discover(_ raw: String) async -> Result<ServerInfo, ServerDiscoveryFailure> {
        let input: URL
        switch ServerDiscovery.normalize(raw) {
        case .success(let url): input = url
        case .failure(let failure): return .failure(failure)
        }
        var document: WellKnownDocument?
        for candidate in ServerDiscovery.wellKnownCandidates(for: input) {
            guard let reply = try? await fetch(candidate), reply.status == 200 else { continue }
            if case .success(let parsed) = ServerDiscovery.parseDocument(reply.body) { document = parsed; break }
        }
        let base = document?.baseURL ?? input
        if let document, ServerDiscovery.isTooOld(current: appVersion, minimum: document.minAppIOS) {
            return .failure(.tooOld(minimum: document.minAppIOS ?? "", current: appVersion))
        }
        guard let health = ServerDiscovery.endpoint(base, path: ServerDiscovery.healthPath) else { return .failure(.invalidInput) }
        let status: Int
        let body: Data
        do {
            (status, body) = try await fetch(health)
        } catch {
            if document == nil { return .failure(.network("\(error)")) }
            return .failure(.healthFailed(baseURL: base, detail: "\(error)"))
        }
        guard status == 200, ServerDiscovery.parseHealth(body) else {
            if document == nil { return .failure(.notFound(host: input.host ?? raw)) }
            return .failure(.healthFailed(baseURL: base, detail: "http_\(status)"))
        }
        if let document {
            return .success(ServerInfo(baseURL: document.baseURL, name: document.name, appLoginPath: document.appLoginPath,
                                       webURL: document.webURL, discoveredVia: .wellKnown, minAppIOS: document.minAppIOS))
        }
        return .success(ServerInfo(baseURL: base, discoveredVia: .direct))
    }

    /// 운영: URLSession GET(요청 하나 `timeout` 초, 리다이렉트는 시스템 기본). 상태코드와 본문만 돌려준다.
    public static func urlSessionFetch(session: URLSession = .shared, timeout: TimeInterval = 10) -> Fetch {
        { url in
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }
}
