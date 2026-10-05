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
}
