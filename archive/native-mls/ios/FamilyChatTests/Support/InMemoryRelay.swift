// 테스트용 메모리 릴레이 — server.go 의 v2 계약 중 2기기 시나리오가 쓰는 부분만(CONTRACTS §2.1).
// 응답은 서버와 같은 JSON 을 만들어 `JSONDecoder` 로 디코드한다(와이어 타입에 public init 이 없고, 와이어 모양도 함께 고정된다).
// `-access-mode disabled`·`-device-state` 없는 격리 릴레이처럼 멤버를 추적하지 않는다(`members: []`).
// `isDown` 은 릴레이 중단(연결 실패 = RelayError.network)을 흉내 낸다. 실 릴레이 스모크는 #276(③)에서 같은 시나리오로 돈다.
import Foundation
import CryptoKit
import FamilyMLSCore

final class InMemoryRelay: RelayTransport, RelayControl {
    private struct Event { var seq: Int64; var device: String; var clientId: String; var kind: String; var epoch: Int64; var bytes: Data; var targets: [String] }
    private struct Room { var epoch: Int64 = 0; var events: [Event] = []; var closed = false; var keyPackages: [String: [(ref: String, bytes: Data)]] = [:]; var cursors: [String: Int64] = [:] }

    private var rooms: [RoomID: Room] = [:]
    private let lock = NSLock()
    private(set) var isDown = false
    private var reads: [RoomID: Int] = [:]

    /// 테스트 관찰: 이 방의 GET /events 횟수.
    func eventReads(room: RoomID) -> Int { lock.withLock { reads[room] ?? 0 } }

    /// #497 B 결함 주입: 다음 application POST 들이 **저장 전에** 이 오류로 실패한다(502 게이트웨이·413 용량 등).
    private var failBeforeStore: [RelayError] = []
    /// #497 B 결함 주입: 다음 application POST 들이 **저장한 뒤** 응답을 잃는다(504 — 릴레이는 받았는데 엣지가 시간 초과).
    private var failAfterStore: [RelayError] = []
    func failNextPosts(_ errors: [RelayError], afterStoring: Bool = false) {
        lock.withLock { if afterStoring { failAfterStore += errors } else { failBeforeStore += errors } }
    }

    /// 테스트 관찰: 이 방에 저장된 application 이벤트 수(같은 글이 두 번 저장됐는지).
    func applicationEvents(room: RoomID) -> Int { lock.withLock { rooms[room]?.events.filter { $0.kind == "application" }.count ?? 0 } }

    /// 테스트 시드(#380): 봇이 `target` 을 더한 commit + 그 기기만을 대상으로 한 Welcome 을 방 로그에 넣는다(바이트는 가짜 — 가짜 엔진용).
    @discardableResult
    func seedWelcome(room: RoomID, target: DeviceID, bot: DeviceID = "bot-gongmyoung") -> Int64 {
        lock.withLock {
            var r = rooms[room] ?? Room()
            let commitSeq = Int64(r.events.count + 1)
            r.events.append(Event(seq: commitSeq, device: bot, clientId: "\(bot)-add-\(commitSeq)", kind: "commit", epoch: r.epoch,
                                  bytes: Data("commit".utf8), targets: []))
            r.epoch += 1
            let welcomeSeq = commitSeq + 1
            r.events.append(Event(seq: welcomeSeq, device: bot, clientId: "\(bot)-welcome-\(welcomeSeq)", kind: "welcome", epoch: r.epoch,
                                  bytes: Data("welcome".utf8), targets: [target]))
            rooms[room] = r
            return welcomeSeq
        }
    }

    /// 테스트 관찰: 이 방의 마지막 Welcome seq(없으면 0).
    func welcomeSeq(room: RoomID) -> Int64 { lock.withLock { rooms[room]?.events.last { $0.kind == "welcome" }?.seq ?? 0 } }

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
            if post.kind == .application, !failBeforeStore.isEmpty { throw failBeforeStore.removeFirst() }
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
            // #562(server.go): 새 application 이벤트를 저장하면 그 기기의 타이핑 신호는 지운다(duplicate 는 아님).
            if post.kind == .application { typing[room]?[post.device] = nil }
            if post.kind == .application, !failAfterStore.isEmpty { throw failAfterStore.removeFirst() }
            return try Self.decode(EventPostResponse.self, ["seq": seq, "epoch": r.epoch, "revision": 0, "duplicate": false])
        }
    }

    // MARK: 타이핑(#562, server/typing.go) — 메모리 전용: 기기별 만료 시각, 읽는 기기 제외, TTL 지난 것은 싣지 않는다.

    private var typing: [RoomID: [DeviceID: Date]] = [:]
    var typingTTL: TimeInterval = 6
    /// 테스트가 시계를 돌릴 수 있게(만료 검사).
    var now: () -> Date = { Date() }
    /// 테스트 관찰: 받은 POST /typing(순서대로).
    private(set) var typingPosts: [(room: RoomID, device: DeviceID, clear: Bool)] = []
    private var typingErrors: [RelayError] = []
    /// 결함 주입: 다음 POST /typing 들이 이 오류로 실패한다(라우트 없는 옛 릴레이 = 404 http_404 등).
    func failNextTypingPosts(_ errors: [RelayError]) { lock.withLock { typingErrors += errors } }

    /// 테스트 시드: 이 방에서 지금 글을 쓰는 기기들(만료는 지금 + TTL). 빈 배열 = 모두 멈춤.
    func setTyping(room: RoomID, devices: [DeviceID]) {
        lock.withLock {
            var entries: [DeviceID: Date] = [:]
            let expires = now().addingTimeInterval(typingTTL)
            for device in devices { entries[device] = expires }
            typing[room] = entries
        }
    }

    func postTyping(room: RoomID, device: DeviceID, clear: Bool) async throws {
        try checkUp()
        try lock.withLock {
            typingPosts.append((room, device, clear))
            if !typingErrors.isEmpty { throw typingErrors.removeFirst() }
            if rooms[room]?.closed == true { throw RelayError.refused(code: "room_closed", status: 410) }
            if clear {
                typing[room]?[device] = nil
            } else {
                typing[room, default: [:]][device] = now().addingTimeInterval(typingTTL)
            }
        }
    }

    /// 응답에 실을 `typing`: 읽는 기기 제외, 만료 제외, 정렬(절대 null 아님).
    private func typingSnapshot(room: RoomID, exclude device: DeviceID) -> [String] {
        let at = now()
        var out: [String] = []
        for (other, expires) in typing[room] ?? [:] where other != device && expires > at { out.append(other) }
        return out.sorted()
    }

    func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage {
        try checkUp()
        return try lock.withLock {
            reads[room, default: 0] += 1
            guard var r = rooms[room], !r.events.isEmpty else { throw RelayError.refused(code: "no_such_room", status: 404) }
            if r.closed { throw RelayError.refused(code: "room_closed", status: 410) }
            if let ack { r.cursors[device] = ack; rooms[room] = r }
            let visible = r.events.filter { $0.seq > after && ($0.kind != "welcome" || $0.targets.contains(device)) }.prefix(limit)
            let events: [[String: Any]] = visible.map {
                ["seq": $0.seq, "device": $0.device, "client_id": $0.clientId, "kind": $0.kind, "epoch": $0.epoch,
                 "bytes": $0.bytes.base64EncodedString(), "sha256": "", "created_at": 0]
            }
            var page: [String: Any] = ["epoch": r.epoch, "revision": 0, "events": events,
                                       "next_after": visible.last?.seq ?? after, "first_seq": 1, "members": [Any](),
                                       "typing": typingSnapshot(room: room, exclude: device)]
            if let cursor = r.cursors[device] { page["cursor"] = cursor }
            return try Self.decode(EventsPage.self, page)
        }
    }

    func closeRoom(room: RoomID, device: DeviceID) async throws {
        try checkUp()
        lock.withLock { rooms[room]?.closed = true }
    }

    // file-v2 blob 저장소(#499, server/blobs.go) — 테스트가 `putBlob` 으로 넣는다. 구성원 검사는 하지 않는다(릴레이 쪽은 Go 테스트).
    private var blobs: [String: Data] = [:]
    private(set) var blobReads: [(room: RoomID, device: DeviceID, id: String)] = []
    func putBlob(id: String, _ bytes: Data) { lock.withLock { blobs[id] = bytes } }

    /// file-v2 송신(#499 3단계): 서버와 같이 id = sha256(본문) 소문자 hex, 201 새로·200 이미 있음. `failNextBlobPosts` 로 거절을 주입한다.
    private var blobPostErrors: [RelayError] = []
    private(set) var blobPosts = 0
    func failNextBlobPosts(_ errors: [RelayError]) { lock.withLock { blobPostErrors += errors } }

    func postBlob(room: RoomID, device: DeviceID, bytes: Data) async throws -> BlobUpload {
        try checkUp()
        let id = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return try lock.withLock {
            blobPosts += 1
            if !blobPostErrors.isEmpty { throw blobPostErrors.removeFirst() }
            if rooms[room]?.closed == true { throw RelayError.refused(code: "room_closed", status: 410) }
            let created = blobs[id] == nil
            blobs[id] = bytes
            return BlobUpload(id: id, size: Int64(bytes.count), created: created)
        }
    }

    func getBlob(room: RoomID, device: DeviceID, id: String) async throws -> Data {
        try checkUp()
        return try lock.withLock {
            blobReads.append((room, device, id))
            if rooms[room]?.closed == true { throw RelayError.refused(code: "room_closed", status: 410) }
            guard let bytes = blobs[id] else { throw RelayError.refused(code: "no_such_blob", status: 404) }
            return bytes
        }
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

    // MARK: 로비(server/lobby.go, #380) — 기기당 live 상한 8, 가장 오래된 것부터 소비, Welcome 목록은 targets ∧ 커서 미통과.

    private var lobby: [DeviceID: [(ref: String, bytes: Data)]] = [:]
    private(set) var lobbyConsumed: [(device: DeviceID, consumer: DeviceID, room: RoomID, ref: String)] = []
    var lobbyMax = 8

    func lobbyLiveCount(_ device: DeviceID) -> Int { lock.withLock { lobby[device]?.count ?? 0 } }

    func postLobbyKeyPackages(_ post: KeyPackagePost) async throws -> KeyPackagesResponse {
        try checkUp()
        return try lock.withLock {
            let live = lobby[post.device] ?? []
            let fresh = post.packages.filter { p in !live.contains { $0.ref == p.ref } }
            guard live.count + fresh.count <= lobbyMax else { throw RelayError.refused(code: "key_package_limit", status: 409) }
            lobby[post.device] = live + fresh.map { ($0.ref, $0.bytes) }
            return try Self.decode(KeyPackagesResponse.self,
                                   ["stored": fresh.count, "duplicates": post.packages.count - fresh.count, "live": live.count + fresh.count])
        }
    }

    func consumeLobbyKeyPackage(device: DeviceID, target: DeviceID, room: RoomID) async throws -> StoredKeyPackage? {
        try checkUp()
        return try lock.withLock {
            if rooms[room]?.closed == true { throw RelayError.refused(code: "room_closed", status: 410) }
            guard var list = lobby[target], !list.isEmpty else { return nil }
            let kp = list.removeFirst()
            lobby[target] = list
            lobbyConsumed.append((target, device, room, kp.ref))
            return try Self.decode(StoredKeyPackage.self, ["ref": kp.ref, "bytes": kp.bytes.base64EncodedString(), "expires_at": 4_000_000_000])
        }
    }

    func lobbyStatus(device: DeviceID) async throws -> LobbyStatus {
        try checkUp()
        return try lock.withLock {
            try Self.decode(LobbyStatus.self, ["device": device, "live": lobby[device]?.count ?? 0, "max": lobbyMax, "ttl_seconds": 2_592_000])
        }
    }

    func deleteLobbyKeyPackages(device: DeviceID) async throws -> Int {
        try checkUp()
        return lock.withLock {
            let n = lobby[device]?.count ?? 0
            lobby[device] = nil
            return n
        }
    }

    func lobbyWelcomes(device: DeviceID) async throws -> [PendingWelcome] {
        try checkUp()
        return try lock.withLock {
            var out: [[String: Any]] = []
            for (name, r) in rooms.sorted(by: { $0.key < $1.key }) where !r.closed {
                let cursor = r.cursors[device] ?? 0
                for ev in r.events where ev.kind == "welcome" && ev.targets.contains(device) && ev.seq > cursor {
                    out.append(["room": name, "seq": ev.seq, "epoch": ev.epoch, "created_at": 0])
                }
            }
            return try Self.decode(LobbyWelcomes.self, ["welcomes": out]).welcomes
        }
    }
}
