// 계약 2 구현 — RelayTransport 의 URLSession 실구현(CONTRACTS.md §2, server.go 2026-10-05 전수 대조).
// 인증(#271 §6-A): accessCookie → `Cookie: CF_Authorization=<jwt>`(엣지가 검증 후 `Cf-Access-Jwt-Assertion` 주입),
// bearer → `Cf-Access-Jwt-Assertion` 헤더 직접(server/auth.go bearerToken — `Authorization: Bearer` 는 툴링 폴백).
// 요청 빌드·오류 매핑은 네트워크 없이 검증 가능한 internal 순수 함수로 분리했다(Linux CI 제약).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class URLSessionRelayTransport: RelayTransport {

    /// 릴레이 오리진(예: `https://relay.example.com`). 경로는 이 클래스가 붙인다.
    public let baseURL: URL
    public let credential: RelayCredential
    public let session: URLSession
    /// 모바일 망 지연 감안. 포그라운드 폴링(4s)보다 훨씬 길게 — 타임아웃은 폴링 리듬이 아니라 왕복 상한이다.
    public var requestTimeout: TimeInterval

    public init(baseURL: URL, credential: RelayCredential, session: URLSession = .shared, requestTimeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.credential = credential
        self.session = session
        self.requestTimeout = requestTimeout
    }

    // MARK: - 요청 빌드 (순수 함수 — 테스트 대상)

    /// server.go 식별자 규칙 `[A-Za-z0-9_-]{1,64}` — URL 에 안전하지만, 방어적으로 percent-encoding 한다.
    /// RFC 3986 unreserved 만 통과(`.urlPathAllowed` 는 `/`·`&` 를 남겨 경로 세그먼트를 깰 수 있다).
    static let pathSegmentAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func pathComponent(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? id
    }

    static func authHeaders(for credential: RelayCredential) -> [String: String] {
        switch credential {
        case .accessCookie(let jwt):
            // Cloudflare Access 세션 쿠키. 서버가 아니라 엣지가 이 쿠키를 검증해 assertion 헤더를 주입한다.
            return ["Cookie": "CF_Authorization=\(jwt)"]
        case .bearer(let jwt):
            // 봇 레인·툴링 폴백: assertion 을 엣지 없이 직접 전달(server/auth.go bearerToken).
            return ["Cf-Access-Jwt-Assertion": jwt]
        }
    }

    func makeRequest(method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        // `path` 는 pathComponent 로 이미 인코딩돼 있으므로 percentEncodedPath 로 넣는다(`.path` 대입은 `%` 를 다시 인코딩한다).
        // 기준 경로는 로컬로 복사(같은 식에서 components 를 읽고 쓰면 Swift 6 exclusivity 오류), 끝 `/` 는 하나로 합친다.
        var basePath = components?.percentEncodedPath ?? ""
        if basePath.hasSuffix("/") { basePath.removeLast() }
        components?.percentEncodedPath = basePath + path
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw RelayError.network("bad relay url: \(baseURL) \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in Self.authHeaders(for: credential) { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    // MARK: - 응답 매핑 (순수 함수 — 테스트 대상)

    /// server.go 오류 분류 → RelayError. 409 cas_mismatch 만 epoch/revision 을 실어 `.cas` 로,
    /// 401 은 `.unauthorized`, 나머지는 코드가 있는 거부로 `.refused`. 코드 없는 비정상 바디도 status 로 격리한다.
    static func relayFailure(status: Int, data: Data) -> RelayError {
        if status == 401 { return .unauthorized }
        let body = try? JSONDecoder().decode(RelayErrorBody.self, from: data)
        if status == 409, body?.error == RelayErrorCode.casMismatch.rawValue,
           let epoch = body?.epoch, let revision = body?.revision {
            return .cas(epoch: epoch, revision: revision)
        }
        return .refused(code: body?.error ?? "http_\(status)", status: status)
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RelayError.decoding("\(T.self): \(error)") }
    }

    /// 공통 왕복: 성공(2xx)이면 바디를 돌려주고, 아니면 relayFailure 매핑으로 던진다.
    func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RelayError.network("\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw RelayError.network("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.relayFailure(status: http.statusCode, data: data)
        }
        return data
    }

    // MARK: - RelayTransport

    public func postKeyPackages(room: RoomID, _ post: KeyPackagePost) async throws -> KeyPackagesResponse {
        let body = try JSONEncoder().encode(post)
        let request = try makeRequest(method: "POST", path: "/v2/rooms/\(Self.pathComponent(room))/keypackages", body: body)
        return try decode(KeyPackagesResponse.self, await perform(request))
    }

    public func consumeKeyPackage(room: RoomID, device: DeviceID, target: DeviceID) async throws -> StoredKeyPackage? {
        // server.go handleConsumeKeyPackage: `device`=패키지 소유자(상대), `consumer`=소비자(나, CF Access subject 로 강제 바인딩).
        let query = [URLQueryItem(name: "device", value: target), URLQueryItem(name: "consumer", value: device)]
        let request = try makeRequest(method: "GET", path: "/v2/rooms/\(Self.pathComponent(room))/keypackages", query: query)
        do {
            return try decode(StoredKeyPackage.self, await perform(request))
        } catch let RelayError.refused(code, status) where status == 404 && code == "no_live_key_package" {
            return nil   // 원자 소비의 정상 공백 — 오류가 아니다.
        }
    }

    public func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse {
        let body = try JSONEncoder().encode(post)
        // 201 created / 200 duplicate(정확 바이트 재전송, K4) — 바디 형태는 동일하다.
        let request = try makeRequest(method: "POST", path: "/v2/rooms/\(Self.pathComponent(room))/events", body: body)
        return try decode(EventPostResponse.self, await perform(request))
    }

    public func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage {
        // ?device= 필수, ?after= 순수 읽기 커서, ?limit= 서버가 min(v,2000) 클램프, ?ack= 만 durable 커서를 움직인다(M2).
        var query = [
            URLQueryItem(name: "device", value: device),
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 2000))),
        ]
        if let ack { query.append(URLQueryItem(name: "ack", value: String(ack))) }
        let request = try makeRequest(method: "GET", path: "/v2/rooms/\(Self.pathComponent(room))/events", query: query)
        return try decode(EventsPage.self, await perform(request))
    }

    public func closeRoom(room: RoomID, device: DeviceID) async throws {
        // §3.4 삭제 경로(B1). 성공 200 {"closed":true} — 이후 모든 계약 라우트는 410 room_closed.
        let request = try makeRequest(method: "POST", path: "/v2/rooms/\(Self.pathComponent(room))/close",
                                      query: [URLQueryItem(name: "device", value: device)])
        _ = try await perform(request)
    }

    // MARK: - 확장 ① (L2 #282 서버 구현) · ② 푸시는 §12-D 전까지 404 refused

    public func listRooms(device: DeviceID) async throws -> RoomsResponse {
        // server rooms.go handleListRooms: JWT subject 의 기기만(타 기기·미등록 403 device_subject_mismatch).
        // 확장 ① 이 없는 옛 릴레이는 404 → `.refused(code:"http_404"…)` 로 그대로 던진다(호출자가 "아는 방만" 으로 폴백).
        return try decode(RoomsResponse.self, await perform(try listRoomsRequest(device: device)))
    }

    func listRoomsRequest(device: DeviceID) throws -> URLRequest {
        try makeRequest(method: "GET", path: "/v2/rooms", query: [URLQueryItem(name: "device", value: device)])
    }

    public func registerPush(_ registration: PushRegistration) async throws {
        throw RelayError.refused(code: "not_found", status: 404)
    }

    public func unregisterPush(device: DeviceID) async throws {
        throw RelayError.refused(code: "not_found", status: 404)
    }
}
