// 테스트용 메모리 릴레이 — server.go 의 v2 계약 중 2기기 시나리오가 쓰는 부분만(CONTRACTS §2.1).
// 응답은 서버와 같은 JSON 을 만들어 `JSONDecoder` 로 디코드한다(와이어 타입에 public init 이 없고, 와이어 모양도 함께 고정된다).
// `-access-mode disabled`·`-device-state` 없는 격리 릴레이처럼 멤버를 추적하지 않는다(`members: []`).
// `isDown` 은 릴레이 중단(연결 실패 = RelayError.network)을 흉내 낸다. 실 릴레이 스모크는 #276(③)에서 같은 시나리오로 돈다.
import Foundation
import FamilyMLSCore

final class InMemoryRelay: RelayTransport, RelayControl {
    private struct Event { var seq: Int64; var device: String; var clientId: String; var kind: String; var epoch: Int64; var bytes: Data; var targets: [String] }
    private struct Room { var epoch: Int64 = 0; var events: [Event] = []; var closed = false; var keyPackages: [String: [(ref: String, bytes: Data)]] = [:]; var cursors: [String: Int64] = [:] }

    private var rooms: [RoomID: Room] = [:]
    private let lock = NSLock()
    private(set) var isDown = false

    func stop() async throws { lock.withLock { isDown = true } }
    func start() async throws { lock.withLock { isDown = false } }

    private func checkUp() throws { if lock.withLock({ isDown }) { throw RelayError.network("relay down (in-memory)") } }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func postKeyPackages(room: RoomID, _ post: KeyPackagePost) async throws -> KeyPackagesResponse {
        try checkUp()
        return try lock.withLock {
            var r = rooms[room] ?? Room()
            if r.closed { throw RelayError.refused(code: "room_closed", status: 410) }
            for p in post.packages { r.keyPackages[post.device, default: []].append((p.ref, p.bytes)) }
            rooms[room] = r
            return try Self.decode(KeyPackagesResponse.self, ["stored": post.packages.count, "duplicates": 0])
        }
    }

    func consumeKeyPackage(room: RoomID, device: DeviceID, target: DeviceID) async throws -> StoredKeyPackage? {
        try checkUp()
        return try lock.withLock {
            guard var r = rooms[room], var list = r.keyPackages[target], !list.isEmpty else { return nil }
            let kp = list.removeFirst()
            r.keyPackages[target] = list
            rooms[room] = r
            return try Self.decode(StoredKeyPackage.self, ["ref": kp.ref, "bytes": kp.bytes.base64EncodedString(), "expires_at": 4_000_000_000])
        }
    }

    func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse {
        try checkUp()
        return try lock.withLock {
            var r = rooms[room] ?? Room()
            if r.closed { throw RelayError.refused(code: "room_closed", status: 410) }
            // K4: 같은 (device, client_id) 의 정확 바이트 재전송 = 200 duplicate(원래 seq). 바이트가 다르면 409 류 거부.
            if let prior = r.events.first(where: { $0.device == post.device && $0.clientId == post.clientId }) {
                guard prior.bytes == post.bytes else { throw RelayError.refused(code: "client_id_conflict", status: 409) }
                return try Self.decode(EventPostResponse.self, ["seq": prior.seq, "epoch": r.epoch, "revision": 0, "duplicate": true])
            }
            guard post.epoch == r.epoch else { throw RelayError.cas(epoch: r.epoch, revision: 0) }
            if post.kind == .welcome && (post.targets ?? []).isEmpty { throw RelayError.refused(code: "welcome_targets_required", status: 400) }
            if post.kind == .commit {
                guard let members = post.members, members.contains(where: { $0.device == post.device }) else {
                    throw RelayError.refused(code: "commit_sender_not_listed", status: 400)
                }
                r.epoch += 1
            }
            let seq = Int64(r.events.count + 1)
            r.events.append(Event(seq: seq, device: post.device, clientId: post.clientId, kind: post.kind.rawValue,
                                  epoch: post.epoch, bytes: post.bytes, targets: post.targets ?? []))
            rooms[room] = r
            return try Self.decode(EventPostResponse.self, ["seq": seq, "epoch": r.epoch, "revision": 0, "duplicate": false])
        }
    }

    func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage {
        try checkUp()
        return try lock.withLock {
            guard var r = rooms[room], !r.events.isEmpty else { throw RelayError.refused(code: "no_such_room", status: 404) }
            if r.closed { throw RelayError.refused(code: "room_closed", status: 410) }
            if let ack { r.cursors[device] = ack; rooms[room] = r }
            let visible = r.events.filter { $0.seq > after && ($0.kind != "welcome" || $0.targets.contains(device)) }.prefix(limit)
            let events: [[String: Any]] = visible.map {
                ["seq": $0.seq, "device": $0.device, "client_id": $0.clientId, "kind": $0.kind, "epoch": $0.epoch,
                 "bytes": $0.bytes.base64EncodedString(), "sha256": "", "created_at": 0]
            }
            var page: [String: Any] = ["epoch": r.epoch, "revision": 0, "events": events,
                                       "next_after": visible.last?.seq ?? after, "first_seq": 1, "members": [Any]()]
            if let cursor = r.cursors[device] { page["cursor"] = cursor }
            return try Self.decode(EventsPage.self, page)
        }
    }

    func closeRoom(room: RoomID, device: DeviceID) async throws {
        try checkUp()
        lock.withLock { rooms[room]?.closed = true }
    }

    func listRooms(device: DeviceID) async throws -> RoomsResponse {
        try checkUp()
        return try lock.withLock {
            let listings: [[String: Any]] = rooms.sorted { $0.key < $1.key }.compactMap { name, r in
                let member = r.events.contains { $0.device == device || $0.targets.contains(device) }
                let outstanding = r.keyPackages[device]?.count ?? 0
                guard member || outstanding > 0 else { return nil }
                return ["room": name, "epoch": r.epoch, "revision": 0, "member": member,
                        "keypackages_outstanding": outstanding, "closed": r.closed]
            }
            return try Self.decode(RoomsResponse.self, ["rooms": listings])
        }
    }

    func registerPush(_ registration: PushRegistration) async throws { throw RelayError.refused(code: "not_found", status: 404) }
    func unregisterPush(device: DeviceID) async throws { throw RelayError.refused(code: "not_found", status: 404) }
}
