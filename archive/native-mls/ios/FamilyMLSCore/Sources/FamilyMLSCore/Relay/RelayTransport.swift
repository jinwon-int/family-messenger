// 계약 2 — 릴레이 전송 경계 (CONTRACTS.md §2). **레인 L3 이 URLSession + CF Access 쿠키로 구현한다.**
// 인증 방식(A: WKWebView 쿠키 / B: 서비스 토큰)은 `RelayCredential` 뒤에 숨긴다. Core 의 동기화 로직은 이 프로토콜만 본다.
import Foundation

public enum RelayCredential: Equatable {
    /// `Cookie: CF_Authorization=<jwt>` — 엣지가 `Cf-Access-Jwt-Assertion` 을 주입(#271 §6-A).
    case accessCookie(String)
    /// `Cf-Access-Jwt-Assertion: <jwt>` 직접(봇 레인·툴링 폴백, server/auth.go).
    case bearer(String)
}

public protocol RelayTransport: AnyObject {
    func postKeyPackages(room: RoomID, _ post: KeyPackagePost) async throws -> KeyPackagesResponse
    /// 상대 기기의 키 패키지 1개를 원자 소비. 없으면 nil.
    func consumeKeyPackage(room: RoomID, device: DeviceID, target: DeviceID) async throws -> StoredKeyPackage?
    func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse
    func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage
    func closeRoom(room: RoomID, device: DeviceID) async throws
    // 확장 ①② — L2 가 서버에 넣기 전에는 `.refused(code:"not_found", status:404)` 를 던진다.
    func listRooms(device: DeviceID) async throws -> RoomsResponse
    func registerPush(_ registration: PushRegistration) async throws
    func unregisterPush(device: DeviceID) async throws

    // 로비 key package(#380 P5-1, server/lobby.go) — 방 무관 풀. 기본 구현은 `.refused(code:"not_found", status:404)`
    // (옛 릴레이·옛 테스트 대역) — 호출자(LobbyKeyring·AppModel)는 404 를 "로비 없음" 으로 보고 건너뛴다.
    /// POST /v2/lobby/keypackages — 이 기기의 로비 키 게시(기기당 live 상한, 만료 TTL).
    func postLobbyKeyPackages(_ post: KeyPackagePost) async throws -> KeyPackagesResponse
    /// GET /v2/lobby/keypackages?device=<상대>&consumer=<나>&room= — 상대의 가장 오래된 로비 키 1개를 `room` 용으로 원자 소비. 없으면 nil.
    func consumeLobbyKeyPackage(device: DeviceID, target: DeviceID, room: RoomID) async throws -> StoredKeyPackage?
    /// GET /v2/lobby/status?device=
    func lobbyStatus(device: DeviceID) async throws -> LobbyStatus
    /// GET /v2/lobby/welcomes?device=
    func lobbyWelcomes(device: DeviceID) async throws -> [PendingWelcome]
    /// DELETE /v2/lobby/keypackages?device= — 이 기기의 미소비 로비 키를 거둔다(#389, 「이 기기 지우기」 직전). 지운 개수.
    func deleteLobbyKeyPackages(device: DeviceID) async throws -> Int
}

public extension RelayTransport {
    func postLobbyKeyPackages(_ post: KeyPackagePost) async throws -> KeyPackagesResponse {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func consumeLobbyKeyPackage(device: DeviceID, target: DeviceID, room: RoomID) async throws -> StoredKeyPackage? {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func lobbyStatus(device: DeviceID) async throws -> LobbyStatus {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func lobbyWelcomes(device: DeviceID) async throws -> [PendingWelcome] {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func deleteLobbyKeyPackages(device: DeviceID) async throws -> Int {
        throw RelayError.refused(code: "not_found", status: 404)
    }
}
