// 릴레이 앞에 끼우는 전송 래퍼: "릴레이는 저장했는데 응답이 사라진" 경우를 만든다(정확 바이트 재전송 → 200 duplicate 검증).
// `dropNextPostResponse` 가 켜져 있으면 다음 events POST 를 그대로 보내고, 받은 응답을 `droppedResponse` 에 남긴 뒤
// RelayError.network 를 던진다 — RoomSyncEngine 은 이 항목을 pending 으로 두고 flushOutbox 에서 같은 바이트로 다시 보낸다.
import Foundation
import FamilyMLSCore

/// 릴레이 중단/재시작 제어(메모리 릴레이 = 플래그, 실 릴레이 = 감독자 프로세스).
protocol RelayControl: AnyObject {
    func stop() async throws
    func start() async throws
}

final class LossyTransport: RelayTransport {
    let base: RelayTransport
    var dropNextPostResponse = false
    private(set) var droppedResponse: EventPostResponse?

    init(base: RelayTransport) { self.base = base }

    func postKeyPackages(room: RoomID, _ post: KeyPackagePost) async throws -> KeyPackagesResponse { try await base.postKeyPackages(room: room, post) }
    func consumeKeyPackage(room: RoomID, device: DeviceID, target: DeviceID) async throws -> StoredKeyPackage? {
        try await base.consumeKeyPackage(room: room, device: device, target: target)
    }
    func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse {
        let response = try await base.postEvent(room: room, post)
        if dropNextPostResponse {
            dropNextPostResponse = false
            droppedResponse = response
            throw RelayError.network("response dropped (test)")
        }
        return response
    }
    func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage {
        try await base.getEvents(room: room, device: device, after: after, limit: limit, ack: ack)
    }
    func closeRoom(room: RoomID, device: DeviceID) async throws { try await base.closeRoom(room: room, device: device) }
    func listRooms(device: DeviceID) async throws -> RoomsResponse { try await base.listRooms(device: device) }
    func registerPush(_ registration: PushRegistration) async throws { try await base.registerPush(registration) }
    func unregisterPush(device: DeviceID) async throws { try await base.unregisterPush(device: device) }
}
