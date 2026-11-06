// 방 순서 동기화(#715 「room-order v1」) — 같은 사람(actor)의 기기들이 한 목록 순서를 쓴다. 릴레이에 actor 단위 메타데이터로 둔다
// (알림 끄기 `mute`·읽음 위치 `read` 와 같은 결, E2EE 본문과 무관). 여기는 와이어 타입과 **순수 판정**만(Linux `swift test`).
//
// 릴레이 계약:
//   GET /v2/me/room-order?device=<id> → 200 {"rooms":[…],"revision":N,"updated_at":<unix>}. 저장된 적 없으면 revision 0.
//   PUT /v2/me/room-order {"device","rooms","base_revision"} → base 가 현재와 같으면 200 {rooms, revision:N+1, updated_at},
//       다르면 409 {"error":"revision_conflict", rooms, revision, updated_at}(= 지금 서버 값). rooms ≤ 64 · 식별자 형식 · 중복 없음(400).
//   옛 릴레이 = 404 → 이 세션은 로컬 순서만(다시 묻지 않는다).
// 클라이언트 규칙(iOS·웹·안드로이드 공통):
//   1. 목록을 불러올 때(시작·로그인·전면 복귀·목록 새로고침, 최소 60초 간격) GET. revision > 0 → 서버 순서 채택(덮어씀).
//      revision 0 이고 로컬에 사용자 순서가 있으면 PUT base 0 으로 **시드**(처음 올리는 기기의 순서가 기준). 409 → 서버 것 채택.
//   2. 사용자가 순서를 바꾸면 로컬에 바로 반영하고 PUT base = 마지막으로 본 revision. 409 → 서버 것 채택.
//   3. 표시 규칙은 그대로(`RoomOrder.apply`): 저장 순서의 방 먼저, 나머지는 기본 순서로 뒤에, 없어진 방 ID 는 무시.
//   4. 404 → 로컬만(세션 동안). 네트워크 오류 → 다음 주기에 다시.
// 이 판정기에서 정한 세부(이슈가 정하지 않은 빈칸):
//   · 올리는 순서 = 화면에 보이는 순서(`localOrder`) — 저장 순서의 방 + 거기 없는 방(기본 순서) + 목록에 없는 저장 ID(뒤, 64개 상한 안에서).
//     그래서 다른 기기는 이 기기와 **같은 화면 순서**를 받는다(아이폰이 시드하면 아이폰 화면 그대로).
//   · revision 을 아직 모를 때(첫 GET 전·GET 중) 바꾼 순서는 버리지 않는다 — GET 이 끝나면 그 revision 을 base 로 올린다(서버 순서로 덮지 않음).
//   · PUT 중에 또 바꾸면 200 뒤에 새 revision 으로 한 번 더 올린다. 409 는 계약대로 서버 것을 채택한다(그 사이 바꾼 것도 접는다).
//   · 409 의 서버 값이 revision 0(릴레이 DB 가 비워졌다)이면 채택하지 않고(빈 순서로 덮지 않음) 로컬을 base 0 으로 다시 시드한다.
//   · 400(형식·중복 거부)은 같은 값을 다시 보내지 않는다(올릴 내용을 `localOrder` 가 미리 걸러 보통은 생기지 않는다).
import Foundation

/// `GET`·`PUT /v2/me/room-order` 의 200 본문, 409 `revision_conflict` 의 현재 값.
public struct RoomOrderState: Equatable, Sendable, Codable {
    public static let routePath = "/v2/me/room-order"
    /// 저장된 적 없음(릴레이 기본값).
    public static let empty = RoomOrderState(rooms: [], revision: 0, updatedAt: 0)

    public var rooms: [RoomID]
    public var revision: Int64
    public var updatedAt: Int64

    public init(rooms: [RoomID], revision: Int64, updatedAt: Int64) {
        self.rooms = rooms; self.revision = revision; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case rooms, revision; case updatedAt = "updated_at" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rooms = try c.decode([RoomID].self, forKey: .rooms)
        revision = try c.decode(Int64.self, forKey: .revision)
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
    }
}

/// `PUT /v2/me/room-order` 본문.
public struct RoomOrderPut: Equatable, Sendable, Encodable {
    public var device: DeviceID
    public var rooms: [RoomID]
    public var baseRevision: Int64
    public init(device: DeviceID, rooms: [RoomID], baseRevision: Int64) {
        self.device = device; self.rooms = rooms; self.baseRevision = baseRevision
    }
    enum CodingKeys: String, CodingKey { case device, rooms; case baseRevision = "base_revision" }
}

/// `PUT` 결과: 200 = 저장됨(새 revision), 409 `revision_conflict` = 다른 기기가 먼저 바꿨다(서버 현재 값).
public enum RoomOrderPutResult: Equatable, Sendable {
    case saved(RoomOrderState)
    case conflict(RoomOrderState)
}

/// 한 세션(로그인 한 번)의 방 순서 동기화 판정. 앱(`AppModel`)이 왕복을 하고 결과를 넣으면 다음 행동(`Action`)을 돌려준다.
/// 한 번에 왕복 하나(`busy`)만 — 그 사이의 사용자 변경은 숫자로 세어 두었다가 왕복이 끝날 때 반영한다.
public struct RoomOrderSync: Equatable, Sendable {
    /// GET 최소 간격(초) — 계약 규칙 1.
    public static let minFetchInterval: TimeInterval = 60
    /// 릴레이 상한(`rooms` 최대 64개).
    public static let maxRooms = 64

    public enum Action: Equatable, Sendable {
        /// 할 일 없음.
        case none
        /// 이 순서를 로컬 저장 순서로(덮어씀).
        case adopt([RoomID])
        /// `PUT` 을 보낸다(이미 `busy` — 결과는 `putFinished`/`failed` 로).
        case put(rooms: [RoomID], baseRevision: Int64)
    }

    public enum Failure: Equatable, Sendable {
        /// 404 — 라우트 없는 옛 릴레이. 이 세션은 로컬만.
        case unsupported
        /// 400 — 릴레이가 본문을 거부했다. 같은 값을 다시 보내지 않는다.
        case rejected
        /// 그 밖(닿지 않음·5xx·403·401·디코드) — 다음 주기에 다시.
        case transient

        public static func classify(_ error: Error) -> Failure {
            guard let relay = error as? RelayError else { return .transient }
            switch relay {
            case .refused(_, let status) where status == 404: return .unsupported
            case .refused(_, let status) where status == 400: return .rejected
            default: return .transient
            }
        }
    }

    private enum Op: Equatable, Sendable { case fetch, put }

    /// 마지막으로 본 서버 revision. nil = 이 세션에서 아직 GET 이 끝나지 않았다.
    public private(set) var revision: Int64?
    /// 404 를 봤다 — 이 세션은 다시 묻지 않는다.
    public private(set) var unsupported = false
    /// 마지막 GET 시작 시각(간격 판정).
    public private(set) var lastFetchAt: Date?
    private var inFlight: Op?
    /// 사용자 변경 횟수 · 서버가 받아들인(또는 접은) 변경까지의 수 · 지금 PUT 이 실은 변경까지의 수.
    private var edits = 0
    private var synced = 0
    private var sending = 0

    public init() {}

    /// 왕복이 진행 중이다.
    public var busy: Bool { inFlight != nil }
    /// 서버에 아직 올리지 못한 사용자 변경이 있다.
    public var hasUnsentEdit: Bool { edits > synced }

    /// 지금 GET 을 시작해도 되는가(404 아님 · 왕복 없음 · 마지막 GET 뒤 60초).
    public func canFetch(now: Date) -> Bool {
        guard !unsupported, inFlight == nil else { return false }
        guard let lastFetchAt else { return true }
        return now.timeIntervalSince(lastFetchAt) >= Self.minFetchInterval
    }

    /// GET 을 시작한다(`canFetch` 가 거짓이면 false — 보내지 않는다).
    public mutating func beginFetch(now: Date) -> Bool {
        guard canFetch(now: now) else { return false }
        inFlight = .fetch
        lastFetchAt = now
        return true
    }

    /// GET 200. `saved` = 지금 로컬 저장 순서, `rooms` = 화면 목록의 방(기본 순서).
    public mutating func fetched(_ server: RoomOrderState, saved: [RoomID], rooms: [RoomID]) -> Action {
        inFlight = nil
        revision = server.revision
        // 첫 GET 전·GET 중에 바꾼 순서: 서버 순서로 덮지 않고 방금 본 revision 위에 올린다(규칙 2).
        if hasUnsentEdit { return push(saved: saved, rooms: rooms, base: server.revision) }
        return applyServer(server, saved: saved, rooms: rooms)
    }

    /// 사용자가 순서를 바꿨다(로컬 저장은 앱이 이미 했다). revision 을 알고 왕복이 없으면 바로 PUT, 아니면 왕복이 끝날 때 올린다.
    public mutating func reordered(saved: [RoomID], rooms: [RoomID]) -> Action {
        edits += 1
        guard !unsupported, inFlight == nil, let revision else { return .none }
        return push(saved: saved, rooms: rooms, base: revision)
    }

    /// PUT 응답.
    public mutating func putFinished(_ result: RoomOrderPutResult, saved: [RoomID], rooms: [RoomID]) -> Action {
        inFlight = nil
        switch result {
        case .saved(let server):
            revision = server.revision
            synced = sending
            // PUT 중에 또 바꿨다 → 새 revision 위에 한 번 더.
            if hasUnsentEdit { return push(saved: saved, rooms: rooms, base: server.revision) }
            return server.rooms == saved ? .none : .adopt(server.rooms)
        case .conflict(let server):
            revision = server.revision
            synced = edits   // 409 → 서버 것 채택(규칙 1·2). 그 사이의 변경도 접는다.
            return applyServer(server, saved: saved, rooms: rooms)
        }
    }

    /// 왕복 실패. 404 → 이 세션 끝, 400(PUT) → 그 변경은 버림, 그 밖 → 변경을 남겨 다음 GET 뒤에 다시 올린다.
    public mutating func failed(_ failure: Failure) {
        let op = inFlight
        inFlight = nil
        switch failure {
        case .unsupported: unsupported = true
        case .rejected: if op == .put { synced = max(synced, sending) }
        case .transient: break
        }
    }

    /// 서버 값을 반영: revision > 0 → 채택, revision 0 → 로컬 사용자 순서가 있으면 시드(PUT base 0), 없으면 그대로.
    private mutating func applyServer(_ server: RoomOrderState, saved: [RoomID], rooms: [RoomID]) -> Action {
        if server.revision > 0 { return server.rooms == saved ? .none : .adopt(server.rooms) }
        return push(saved: saved, rooms: rooms, base: 0)
    }

    private mutating func push(saved: [RoomID], rooms: [RoomID], base: Int64) -> Action {
        let order = Self.localOrder(saved: saved, rooms: rooms)
        guard !order.isEmpty else { synced = edits; return .none }   // 사용자 순서 없음 — 올릴 것이 없다
        inFlight = .put
        sending = edits
        return .put(rooms: order, baseRevision: base)
    }

    /// 릴레이에 올릴 순서 = 이 기기 화면 순서. 사용자 순서(`saved`)가 없으면 빈 배열(시드하지 않는다 — 기본 순서는 「사용자 순서」가 아니다).
    /// `RoomOrder.apply` 와 같은 순서(저장 순서의 방 → 나머지 방 기본 순서) 뒤에 목록에 없는 저장 ID 를 붙이고,
    /// 형식이 틀린 ID·중복을 빼고 64개로 자른다(릴레이 400 을 미리 피한다).
    public static func localOrder(saved: [RoomID], rooms: [RoomID]) -> [RoomID] {
        guard !saved.isEmpty else { return [] }
        let present = Set(rooms)
        var seen = Set<RoomID>()
        var out: [RoomID] = []
        func add(_ id: RoomID) {
            guard out.count < maxRooms, isValidRoomID(id), seen.insert(id).inserted else { return }
            out.append(id)
        }
        for id in saved where present.contains(id) { add(id) }
        for id in rooms { add(id) }
        for id in saved { add(id) }
        return out
    }

    /// 릴레이 식별자 규칙 `[A-Za-z0-9_-]{1,64}`(server.go `validIdentifier`).
    public static func isValidRoomID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { (b: UInt8) -> Bool in
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"):
                return true
            default:
                return false
            }
        }
    }
}
