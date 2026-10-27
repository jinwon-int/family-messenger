// URLSessionRelayTransport — 네트워크 없이 검증 가능한 순수 경로만 계약 고정.
// (authHeaders / relayFailure / pathComponent / decode / makeRequest URL·쿼리·헤더)
// 실제 왕복(perform)은 Linux corelibs URLSession 이 커스텀 URLProtocol 을 타지 않아 CI 에서 모킹 불가 —
// 상태·코드 분류는 static relayFailure 로 전수 고정하고, 와이어 왕립은 server.go 대조 테스트(RelayTypesTests)와
// 라이브 스모크로 담보한다. server.go 2026-10-05 전수 대조 기준.
import XCTest
@testable import FamilyMLSCore

final class RelayTransportTests: XCTestCase {
    private let baseURL = URL(string: "https://relay.example.com")!

    private func transport(_ credential: RelayCredential, timeout: TimeInterval = 30) -> URLSessionRelayTransport {
        URLSessionRelayTransport(baseURL: baseURL, credential: credential, requestTimeout: timeout)
    }

    // MARK: - authHeaders (인증 #271 §6-A)

    func testAuthHeadersAccessCookieUsesCFAuthorizationCookie() {
        let headers = URLSessionRelayTransport.authHeaders(for: .accessCookie("jwt-abc"))
        XCTAssertEqual(headers, ["Cookie": "CF_Authorization=jwt-abc"])
    }

    func testAuthHeadersBearerUsesAssertionHeaderDirectly() {
        let headers = URLSessionRelayTransport.authHeaders(for: .bearer("jwt-xyz"))
        XCTAssertEqual(headers, ["Cf-Access-Jwt-Assertion": "jwt-xyz"])
        XCTAssertNil(headers["Cookie"], "bearer 는 쿠키를 쓰지 않는다")
    }

    // MARK: - pathComponent (방어적 인코딩)

    func testPathComponentLeavesWellFormedIDsAlone() {
        XCTAssertEqual(URLSessionRelayTransport.pathComponent("owner-pc_1"), "owner-pc_1")
    }

    func testPathComponentEncodesURLHostileCharacters() {
        XCTAssertEqual(URLSessionRelayTransport.pathComponent("a b?c/d&e"), "a%20b%3Fc%2Fd%26e")
    }

    // MARK: - relayFailure (server.go 오류 분류 전수)

    private func body(_ json: String) -> Data { Data(json.utf8) }

    func testRelayFailure401WinsBeforeBodyDecode() {
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 401, data: body(#"{"error":"cas_mismatch"}"#)), .unauthorized)
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 401, data: Data("not json".utf8)), .unauthorized)
    }

    func testRelayFailure409CasCarriesEpochAndRevision() {
        XCTAssertEqual(
            URLSessionRelayTransport.relayFailure(status: 409, data: body(#"{"error":"cas_mismatch","epoch":4,"revision":7}"#)),
            .cas(epoch: 4, revision: 7))
    }

    func testRelayFailure409CasWithoutStateFallsBackToRefused() {
        XCTAssertEqual(
            URLSessionRelayTransport.relayFailure(status: 409, data: body(#"{"error":"cas_mismatch"}"#)),
            .refused(code: "cas_mismatch", status: 409))
    }

    func testRelayFailureRefusedCodesPassThrough() {
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 403, data: body(#"{"error":"device_subject_mismatch"}"#)),
                       .refused(code: "device_subject_mismatch", status: 403))
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 410, data: body(#"{"error":"room_closed"}"#)),
                       .refused(code: "room_closed", status: 410))
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 404, data: body(#"{"error":"no_live_key_package"}"#)),
                       .refused(code: "no_live_key_package", status: 404))
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 409, data: body(#"{"error":"not_a_member"}"#)),
                       .refused(code: "not_a_member", status: 409))
    }

    func testRelayFailureUndecodableBodyIsolatedByStatus() {
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 500, data: Data("<html>oops</html>".utf8)),
                       .refused(code: "http_500", status: 500))
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 503, data: Data()),
                       .refused(code: "http_503", status: 503))
    }

    // MARK: - makeRequest (URL · 쿼리 · 헤더 빌드)

    func testConsumeKeyPackageQueryIsDeviceTargetAndConsumerDevice() throws {
        let request = try transport(.bearer("t")).makeRequest(
            method: "GET", path: "/v2/rooms/r1/keypackages",
            query: [URLQueryItem(name: "device", value: "mate-pc"), URLQueryItem(name: "consumer", value: "me-pc")])
        XCTAssertEqual(request.url?.absoluteString,
                       "https://relay.example.com/v2/rooms/r1/keypackages?device=mate-pc&consumer=me-pc")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"), "t")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"), "바디 없는 GET 에 Content-Type 을 붙이지 않는다")
    }

    func testGetEventsQueryOrderAndOptionalAck() throws {
        let base = [URLQueryItem(name: "device", value: "me-pc"),
                    URLQueryItem(name: "after", value: "11"),
                    URLQueryItem(name: "limit", value: "50")]
        let without = try transport(.accessCookie("ck")).makeRequest(method: "GET", path: "/v2/rooms/r1/events", query: base)
        XCTAssertEqual(without.url?.query, "device=me-pc&after=11&limit=50")
        XCTAssertNil(without.url?.absoluteString.range(of: "ack="), "ack nil 은 ?ack= 를 붙이지 않는다(durable 커서 이동 금지)")
        XCTAssertEqual(without.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=ck")

        let with = try transport(.accessCookie("ck")).makeRequest(
            method: "GET", path: "/v2/rooms/r1/events", query: base + [URLQueryItem(name: "ack", value: "12")])
        XCTAssertEqual(with.url?.query, "device=me-pc&after=11&limit=50&ack=12")
    }

    func testGetEventsLimitClampedToServerWindow() throws {
        func limitInQuery(_ raw: Int) throws -> String {
            let request = try transport(.bearer("t")).makeRequest(
                method: "GET", path: "/v2/rooms/r1/events",
                query: [URLQueryItem(name: "limit", value: String(min(max(raw, 1), 2000)))])
            return try XCTUnwrap(request.url?.query)
        }
        XCTAssertEqual(try limitInQuery(0), "limit=1")
        XCTAssertEqual(try limitInQuery(1), "limit=1")
        XCTAssertEqual(try limitInQuery(2000), "limit=2000")
        XCTAssertEqual(try limitInQuery(9999), "limit=2000")
    }

    func testPostRequestCarriesJSONBodyAndContentType() throws {
        let bodyData = Data(#"{"device":"me-pc"}"#.utf8)
        let request = try transport(.bearer("t")).makeRequest(
            method: "POST", path: "/v2/rooms/r1/events", query: [], body: bodyData)
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/v2/rooms/r1/events")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, bodyData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testCloseRoomUsesDeviceQueryOnClosePath() throws {
        let request = try transport(.bearer("t")).makeRequest(
            method: "POST", path: "/v2/rooms/r1/close",
            query: [URLQueryItem(name: "device", value: "me-pc")])
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/v2/rooms/r1/close?device=me-pc")
    }

    func testRequestTimeoutPropagates() throws {
        let request = try transport(.bearer("t"), timeout: 4.5).makeRequest(method: "GET", path: "/v2/rooms/r1/events")
        XCTAssertEqual(request.timeoutInterval, 4.5)
    }

    func testPathEncodingSurvivesURLBuild() throws {
        let request = try transport(.bearer("t")).makeRequest(
            method: "GET", path: "/v2/rooms/\(URLSessionRelayTransport.pathComponent("a b")).keypackages")
        XCTAssertEqual(request.url?.path, "/v2/rooms/a b.keypackages", "percent-encoding 은 URL 빌드에서 원문으로 복원된다")
    }

    // MARK: - decode (바디 → 계약 타입, 실패는 .decoding 격리)

    func testDecodeStoredKeyPackageSnakeCase() throws {
        let stored = try transport(.bearer("t")).decode(
            StoredKeyPackage.self, body(#"{"ref":"kp-1","bytes":"AQID","expires_at":1700000123}"#))
        XCTAssertEqual(stored, StoredKeyPackage(ref: "kp-1", bytes: Data([1, 2, 3]), expiresAt: 1_700_000_123))
    }

    func testDecodeFailureThrowsRelayErrorDecoding() {
        XCTAssertThrowsError(try transport(.bearer("t")).decode(StoredKeyPackage.self, Data("[".utf8))) { error in
            guard case RelayError.decoding(let message) = error else {
                return XCTFail("expected .decoding, got \(error)")
            }
            XCTAssertTrue(message.contains("StoredKeyPackage"))
        }
    }

    // MARK: - 확장 ① 방 목록(#282 서버 구현) · ② 푸시 등록(#275 서버 구현, §12-D)

    /// file-v2 blob GET(#499, server/blobs.go): GET /v2/rooms/{room}/blobs/{id}?device= · 원시 바이트(Accept octet-stream) · 같은 인증 헤더.
    func testGetBlobRequestMatchesServerWire() throws {
        let id = String(repeating: "ab", count: 32)
        let request = try transport(.bearer("t")).getBlobRequest(room: "family", device: "me-pc", id: id)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/v2/rooms/family/blobs/\(id)?device=me-pc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"), "t")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
        XCTAssertNil(request.httpBody)
        let weird = try transport(.bearer("t")).getBlobRequest(room: "fa/mily", device: "me-pc", id: "x/../y")
        XCTAssertEqual(weird.url?.absoluteString, "https://relay.example.com/v2/rooms/fa%2Fmily/blobs/x%2F..%2Fy?device=me-pc",
                       "ids stay one path segment each")
    }

    /// file-v2 송신(#499 3단계): POST /v2/rooms/{room}/blobs?device= · 본문 = 원시 암호문 · Content-Type octet-stream.
    func testPostBlobRequestMatchesServerWire() throws {
        let bytes = Data([1, 2, 3, 0xFF])
        let request = try transport(.bearer("t")).postBlobRequest(room: "family", device: "me-pc", bytes: bytes)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/v2/rooms/family/blobs?device=me-pc")
        XCTAssertEqual(request.httpBody, bytes)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"), "t")
        let upload = try JSONDecoder().decode(BlobUpload.self, from: Data(#"{"id":"ab","size":4}"#.utf8))
        XCTAssertEqual(upload, BlobUpload(id: "ab", size: 4, created: false))
    }

    func testDefaultGetBlobIsNotFound() async {
        final class Bare: RelayTransport {
            func postKeyPackages(room: RoomID, _ post: KeyPackagePost) async throws -> KeyPackagesResponse { fatalError() }
            func consumeKeyPackage(room: RoomID, device: DeviceID, target: DeviceID) async throws -> StoredKeyPackage? { nil }
            func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse { fatalError() }
            func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage { fatalError() }
            func closeRoom(room: RoomID, device: DeviceID) async throws {}
            func listRooms(device: DeviceID) async throws -> RoomsResponse { fatalError() }
            func registerPush(_ registration: PushRegistration) async throws {}
            func unregisterPush(device: DeviceID) async throws {}
        }
        do { _ = try await Bare().getBlob(room: "family", device: "me-pc", id: "x"); XCTFail("default must throw") }
        catch { XCTAssertEqual(error as? RelayError, .refused(code: "not_found", status: 404)) }
    }

    func testListRoomsRequestAndDecode() throws {
        let request = try transport(.bearer("t")).listRoomsRequest(device: "me-pc")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/v2/rooms?device=me-pc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"), "t")
        let listing = try transport(.bearer("t")).decode(RoomsResponse.self, body(
            #"{"rooms":[{"room":"family","epoch":3,"revision":5,"member":true,"keypackages_outstanding":0,"closed":false}]}"#))
        XCTAssertEqual(listing.rooms, [RoomListing(room: "family", epoch: 3, revision: 5, member: true, keypackagesOutstanding: 0, closed: false)])
    }

    /// server push.go handleRegisterPush: POST /v2/push/devices, JSON {device, apns_token(std base64), topic} — strictJSON 이라 다른 키 없음.
    func testRegisterPushRequestMatchesServerWire() throws {
        let token = Data((0..<32).map { UInt8($0) })
        let request = try transport(.bearer("t")).registerPushRequest(
            PushRegistration(device: "owner-iphone-0a0b0c", apnsToken: token, topic: "com.seoyoon-family.hande"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/v2/push/devices")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"), "t")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["device", "apns_token", "topic"])
        XCTAssertEqual(json["device"] as? String, "owner-iphone-0a0b0c")
        XCTAssertEqual(json["apns_token"] as? String, token.base64EncodedString(), "표준 base64(서버 encoding/json []byte)")
        XCTAssertEqual(json["topic"] as? String, "com.seoyoon-family.hande")
    }

    func testRegisterPushRequestUsesAccessCookieBehindEdge() throws {
        let request = try transport(.accessCookie("jwt")).registerPushRequest(
            PushRegistration(device: "me-pc", apnsToken: Data([1]), topic: "com.example.app"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=jwt")
    }

    /// server push.go handleUnregisterPush: DELETE /v2/push/devices?device= (바디 없음).
    func testUnregisterPushRequestMatchesServerWire() throws {
        let request = try transport(.bearer("t")).unregisterPushRequest(device: "owner-iphone-0a0b0c")
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/v2/push/devices?device=owner-iphone-0a0b0c")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"), "t")
    }

    // MARK: - 로비(server/lobby.go, #380 P5-1) — 4 라우트의 URL·쿼리·바디

    func testLobbyRequestsMatchServerRoutes() throws {
        let t = transport(.bearer("t"))
        let post = try t.postLobbyKeyPackagesRequest(KeyPackagePost(device: "owner-iphone-1", packages: [KeyPackageInput(ref: "abcd", bytes: Data([1, 2]))]))
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.absoluteString, "https://relay.example.com/v2/lobby/keypackages")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(post.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["device", "packages"], "방별 게시와 같은 바디(readKeyPackagePost) — room 은 없다")
        XCTAssertEqual(((json["packages"] as? [[String: Any]])?.first?["ref"]) as? String, "abcd")

        let consume = try t.consumeLobbyKeyPackageRequest(device: "me-pc", target: "mom-iphone-1", room: "ops-yukson")
        XCTAssertEqual(consume.httpMethod, "GET")
        XCTAssertEqual(consume.url?.absoluteString,
                       "https://relay.example.com/v2/lobby/keypackages?device=mom-iphone-1&consumer=me-pc&room=ops-yukson",
                       "device=상대(패키지 소유자) · consumer=나 · room=쓸 방")
        XCTAssertEqual(try t.lobbyStatusRequest(device: "me-pc").url?.absoluteString, "https://relay.example.com/v2/lobby/status?device=me-pc")
        XCTAssertEqual(try t.lobbyWelcomesRequest(device: "me-pc").url?.absoluteString, "https://relay.example.com/v2/lobby/welcomes?device=me-pc")
        XCTAssertEqual(try t.lobbyWelcomesRequest(device: "me-pc").httpMethod, "GET")
        let delete = try t.deleteLobbyKeyPackagesRequest(device: "me-pc")
        XCTAssertEqual(delete.httpMethod, "DELETE", "#389")
        XCTAssertEqual(delete.url?.absoluteString, "https://relay.example.com/v2/lobby/keypackages?device=me-pc")
        XCTAssertNil(delete.httpBody)
    }

    func testLobbyRefusalsMapLikeOtherRoutes() {
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 403, data: body(#"{"error":"device_not_allowed","detail":"x"}"#)),
                       .refused(code: "device_not_allowed", status: 403))
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 409, data: body(#"{"error":"key_package_limit","live":8,"max":8}"#)),
                       .refused(code: "key_package_limit", status: 409))
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 404, data: body(#"{"error":"no_live_key_package"}"#)),
                       .refused(code: "no_live_key_package", status: 404))
    }

    /// 로비 라우트를 구현하지 않은 전송(옛 테스트 대역·옛 릴레이)은 프로토콜 기본 구현이 404 를 던진다 — 호출자가 "로비 없음" 으로 건너뛴다.
    func testTransportWithoutLobbyDefaultsTo404() async {
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
        await XCTAssertThrowsErrorAsync(try await legacy.lobbyStatus(device: "me")) { XCTAssertEqual($0 as? RelayError, .refused(code: "not_found", status: 404)) }
        await XCTAssertThrowsErrorAsync(try await legacy.lobbyWelcomes(device: "me")) { XCTAssertEqual($0 as? RelayError, .refused(code: "not_found", status: 404)) }
        await XCTAssertThrowsErrorAsync(try await legacy.consumeLobbyKeyPackage(device: "me", target: "you", room: "r")) {
            XCTAssertEqual($0 as? RelayError, .refused(code: "not_found", status: 404))
        }
        await XCTAssertThrowsErrorAsync(try await legacy.deleteLobbyKeyPackages(device: "me")) { XCTAssertEqual($0 as? RelayError, .refused(code: "not_found", status: 404)) }
    }

    /// 등록 라우트의 서버 거부는 다른 라우트와 같은 매핑(재로그인·등록 대기·설정 오류를 호출자가 가른다).
    func testPushRefusalsMapLikeOtherRoutes() {
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 401, data: Data()), .unauthorized)
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 403, data: body(#"{"error":"device_subject_mismatch"}"#)),
                       .refused(code: "device_subject_mismatch", status: 403))
        XCTAssertEqual(URLSessionRelayTransport.relayFailure(status: 400, data: body(#"{"error":"topic_not_allowed"}"#)),
                       .refused(code: "topic_not_allowed", status: 400))
    }
}

/// Linux CI 호환 비동기 throw 단정 헬퍼(XCTest 의 async XCTAssertThrowsError 부재 보완).
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  _ handler: @escaping (Error) -> Void) async {
    do {
        _ = try await expression()
        XCTFail("expected error, got success")
    } catch {
        handler(error)
    }
}
