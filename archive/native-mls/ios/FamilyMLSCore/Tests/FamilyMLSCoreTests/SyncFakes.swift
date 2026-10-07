// RoomSyncEngine 테스트 대역 (#276 L3) — 가짜 MLS 엔진·팩토리, 메모리 릴레이(RelayTransport), 메모리 MessageStore,
// "트랜잭션 안인가" 를 아는 상태 저장소. 실 MLS 는 없다: 엔진 상태는 JSON(멤버·대기/스테이지 roster·ratchet 카운터)이고
// commit/Welcome 바이트도 테스트가 만든 JSON 이다. 엔진 계약(거부 시 연산 전 상태 유지)은 "검사 후 변경" 순서로 지킨다.
import Foundation
@testable import FamilyMLSCore

// MARK: - 와이어 헬퍼

enum FakeWire {
    static func u32(_ v: Int) -> Data { var le = UInt32(v).littleEndian; return Data(bytes: &le, count: 4) }

    /// 멤버 리스트 1개: u32le count ‖ (u32le idLen ‖ id ‖ 32B key)*
    static func memberList(_ ids: [String]) -> Data {
        var out = u32(ids.count)
        for id in ids {
            let bytes = Data(id.utf8)
            out.append(u32(bytes.count)); out.append(bytes); out.append(Data(repeating: 0x11, count: 32))
        }
        return out
    }

    static func stageReport(adds: [String], removes: [String], updates: [String], path: [String]) -> Data {
        memberList(adds) + memberList(removes) + memberList(updates) + memberList(path)
    }
}

/// 테스트가 릴레이에 넣는 commit 바이트(JSON).
struct FakeCommit: Codable {
    var committer: String
    var adds: [String] = []
    var removes: [String] = []
    var updates: [String] = []
    /// nil = [committer]
    var path: [String]?
    /// stage_commit 이 거부(poison).
    var poison = false
    /// stage_commit 이 report 형식이 아닌 바이트를 돌려준다.
    var badReport = false

    var bytes: Data { try! JSONEncoder().encode(self) }
}

/// Welcome 바이트(JSON): 참여 뒤 그룹 멤버.
struct FakeWelcome: Codable {
    var members: [String]
    var poison = false
    var bytes: Data { try! JSONEncoder().encode(self) }
}

// MARK: - 엔진

struct FakeEngineState: Codable, Equatable {
    var members: [String]?        // nil = 그룹 없음(참여 전)
    var epoch: Int64 = 0
    var pending: [String]?        // 내 commit 대기(merge_pending 대상)
    var staged: [String]?         // stage_commit 결과(merge_staged 대상)
    var sendGeneration = 0
    var receiveGeneration = 0

    static func joined(_ members: [String], epoch: Int64 = 1, pending: [String]? = nil) -> FakeEngineState {
        FakeEngineState(members: members, epoch: epoch, pending: pending)
    }
    var bytes: Data { try! JSONEncoder().encode(self) }
    static func decode(_ data: Data) -> FakeEngineState { try! JSONDecoder().decode(FakeEngineState.self, from: data) }
}

/// 엔진 호출 기록(메서드 wire 이름) — 처리 순서 단언용. 팩토리가 만든 모든 인스턴스가 공유한다.
final class EngineLog {
    var calls: [String] = []
    var imports = 0
    func count(_ method: EngineMethod) -> Int { calls.filter { $0 == method.rawValue }.count }
}

final class FakeMlsEngine: MlsEngine {
    static let ciphertextMagic = Data("FAKE".utf8)
    let identity: DeviceID
    var state: FakeEngineState
    let log: EngineLog

    init(identity: DeviceID, state: FakeEngineState, log: EngineLog) {
        self.identity = identity; self.state = state; self.log = log
    }

    func dispatch(_ method: EngineMethod, _ input: Data) throws -> Data {
        log.calls.append(method.rawValue)
        switch method {
        case .members:
            guard let members = state.members else { throw EngineError.rejected("no_group") }
            return FakeWire.memberList(members)
        case .join:
            guard state.members == nil else { throw EngineError.rejected("already_joined") }
            guard let welcome = try? JSONDecoder().decode(FakeWelcome.self, from: input), !welcome.poison,
                  welcome.members.contains(identity) else { throw EngineError.rejected("bad_welcome") }
            state.members = welcome.members.sorted()
            state.epoch += 1
            return Data()
        case .stageCommit:
            guard state.members != nil, state.staged == nil else { throw EngineError.rejected("no_group") }
            guard let commit = try? JSONDecoder().decode(FakeCommit.self, from: input), !commit.poison else {
                throw EngineError.rejected("bad_commit")
            }
            var next = Set(state.members ?? [])
            next.subtract(commit.removes); next.formUnion(commit.adds)
            state.staged = next.sorted()
            if commit.badReport { return Data([0x01, 0x02, 0x03]) }
            return FakeWire.stageReport(adds: commit.adds, removes: commit.removes, updates: commit.updates,
                                        path: commit.path ?? [commit.committer])
        case .mergeStaged:
            guard let staged = state.staged else { throw EngineError.rejected("nothing_staged") }
            state.members = staged; state.staged = nil; state.epoch += 1
            return Data()
        case .discardStaged:
            state.staged = nil
            return Data()
        case .mergePending:
            guard let pending = state.pending else { throw EngineError.rejected("nothing_pending") }
            state.members = pending; state.pending = nil; state.epoch += 1
            return Data()
        case .clearPending:
            state.pending = nil
            return Data()
        case .encrypt:
            guard state.members?.contains(identity) == true else { throw EngineError.rejected("no_group") }
            var offset = 0
            _ = try Framing.readString(input, &offset)                 // room (AAD)
            let clientId = try Framing.readString(input, &offset)
            let plaintext = input.subdata(in: offset..<input.count)
            state.sendGeneration += 1
            // "암호문" = magic ‖ (decrypt 출력 형식: sender ‖ client_id ‖ plaintext) ‖ 송신 generation(재암호화면 바이트가 달라진다)
            var plain = plaintext
            plain.append(contentsOf: [UInt8(truncatingIfNeeded: state.sendGeneration)])
            return Self.ciphertextMagic + Framing.encryptInput(room: identity, clientId: clientId, plaintext: plain)
        case .decrypt:
            guard state.members != nil else { throw EngineError.rejected("no_group") }
            var offset = 0
            _ = try Framing.readString(input, &offset)
            let ciphertext = input.subdata(in: offset..<input.count)
            guard ciphertext.starts(with: Self.ciphertextMagic) else { throw EngineError.rejected("undecryptable") }
            state.receiveGeneration += 1
            var framed = ciphertext.dropFirst(Self.ciphertextMagic.count)
            framed = framed.dropLast()   // 송신 generation 바이트 제거
            // 파사드 Device.decrypt 와 같은 귀속 검사(리뷰 H1, openmls-browser lib.rs decrypt_checked_inner):
            // AAD client_id 는 MLS 로 인증된 발신 기기 ID 와 정확히 같아야 한다. 릴레이 client_id(dedup 키)와는 별개.
            var at = 0
            let sender = try Framing.readString(Data(framed), &at)
            let aadClient = try Framing.readString(Data(framed), &at)
            guard aadClient == sender else { throw EngineError.rejected("sender attribution rejected") }
            return Data(framed)
        default:
            throw EngineError.invalid("fake engine: \(method.rawValue) not modelled")
        }
    }

    func exportState() throws -> Data { state.bytes }
    func publicKey() throws -> Data { Data(repeating: 0xAB, count: 32) }
    func fingerprint() throws -> String { "fp-\(identity)" }
    func hasPending() throws -> Bool { state.pending != nil }
}

final class FakeEngineFactory: MlsEngineFactory {
    let log = EngineLog()
    func create(identity: DeviceID) throws -> MlsEngine {
        FakeMlsEngine(identity: identity, state: FakeEngineState(), log: log)
    }
    func importState(identity: DeviceID, bytes: Data) throws -> MlsEngine {
        log.imports += 1
        return FakeMlsEngine(identity: identity, state: FakeEngineState.decode(bytes), log: log)
    }
}

// MARK: - 상태 저장소 (트랜잭션 감시)

/// InMemoryStateStore 를 감싸 "지금 withExclusive body 안인가" 를 노출한다. FakeRelay 가 매 호출에서 이것을 본다.
final class GuardedStateStore: MlsStateStore {
    let inner: InMemoryStateStore
    private(set) var inTransaction = false
    private(set) var transactions = 0

    init(inner: InMemoryStateStore = InMemoryStateStore()) { self.inner = inner }

    func withExclusive<T>(room: RoomID, timeout: TimeInterval, _ body: (StateTransaction) throws -> T) throws -> T {
        try inner.withExclusive(room: room, timeout: timeout) { tx in
            inTransaction = true
            transactions += 1
            defer { inTransaction = false }
            return try body(tx)
        }
    }

    func generation(room: RoomID) throws -> UInt64 { try inner.generation(room: room) }

    /// 테스트 시드/검사: 트랜잭션으로 저장된 가짜 엔진 상태.
    func seed(room: RoomID, _ state: FakeEngineState) throws {
        try inner.withExclusive(room: room, timeout: 1) { tx in try tx.save(state.bytes) }
    }
    func engineState(room: RoomID) throws -> FakeEngineState? {
        try inner.withExclusive(room: room, timeout: 1) { tx in try tx.load().map(FakeEngineState.decode) }
    }
}

// MARK: - 릴레이

/// server.go v2 의 events 의미를 메모리로: seq 증가, epoch CAS(409), (device, client_id) 정확 바이트 재전송 = 200 duplicate,
/// 바이트가 다르면 409 client_id_reuse, commit 은 epoch 을 올린다. 모든 호출은 `guardStore.inTransaction` 이면 위반으로 기록된다.
final class FakeRelay: RelayTransport {
    var rows: [StoredEvent] = []
    var epoch: Int64 = 0
    var revision: Int64 = 0
    /// 페이지의 `members`(릴레이가 추적하는 outer roster). nil = 응답에 없음.
    var members: [String]?
    var firstSeq: Int64?
    var getCalls: [(after: Int64, ack: Int64?)] = []
    var posts: [EventPost] = []
    var getErrors: [RelayError] = []
    var postErrors: [RelayError] = []
    /// 다음 POST 1회: 저장은 하고 응답을 잃는다(네트워크 오류) — 정확 바이트 재시도 시나리오.
    var dropNextPostResponse = false
    /// POST 를 받는 순간 호출(바이트가 나가기 전에 상태가 저장됐는지 등 검사용).
    var onPost: ((EventPost) -> Void)?
    weak var guardStore: GuardedStateStore?
    private(set) var violations: [String] = []

    func check(_ op: String) {
        if guardStore?.inTransaction == true { violations.append(op) }
    }

    /// 다른 기기가 올린 이벤트. commit 은 epoch 을 올리고, 이벤트 epoch 은 올리기 전 값(server.go 와 같음).
    @discardableResult
    func inject(device: DeviceID, kind: EventKind, bytes: Data, clientId: String? = nil) -> Int64 {
        let seq = (rows.last?.seq ?? 0) + 1
        rows.append(StoredEvent(seq: seq, device: device, clientId: clientId ?? "\(device)-\(seq)", kind: kind, epoch: epoch,
                                bytes: bytes, sha256: "", createdAt: 0))
        if kind == .commit { epoch += 1; revision += 1 }
        return seq
    }

    func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse {
        check("postEvent")
        posts.append(post)
        onPost?(post)
        if !postErrors.isEmpty { throw postErrors.removeFirst() }
        if let existing = rows.first(where: { $0.device == post.device && $0.clientId == post.clientId }) {
            guard existing.bytes == post.bytes else { throw RelayError.refused(code: "client_id_reuse", status: 409) }
            return EventPostResponse(seq: existing.seq, epoch: epoch, revision: revision, duplicate: true)
        }
        guard post.epoch == epoch else { throw RelayError.cas(epoch: epoch, revision: revision) }
        let seq = inject(device: post.device, kind: post.kind, bytes: post.bytes, clientId: post.clientId)
        if dropNextPostResponse { dropNextPostResponse = false; throw RelayError.network("response lost") }
        return EventPostResponse(seq: seq, epoch: epoch, revision: revision, duplicate: false)
    }

    func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage {
        check("getEvents")
        getCalls.append((after, ack))
        if !getErrors.isEmpty { throw getErrors.removeFirst() }
        let events = Array(rows.filter { $0.seq > after }.prefix(limit))
        return EventsPage(epoch: epoch, revision: revision, events: events, nextAfter: events.last?.seq ?? after,
                          cursor: ack, firstSeq: firstSeq ?? rows.first?.seq,
                          members: members.map { $0.map { MemberWire(device: $0, actor: String($0.split(separator: "-").first ?? "")) } })
    }

    func postKeyPackages(room: RoomID, _ post: KeyPackagePost) async throws -> KeyPackagesResponse {
        check("postKeyPackages"); return KeyPackagesResponse(stored: post.packages.count, duplicates: 0)
    }
    func consumeKeyPackage(room: RoomID, device: DeviceID, target: DeviceID) async throws -> StoredKeyPackage? {
        check("consumeKeyPackage"); return nil
    }
    func closeRoom(room: RoomID, device: DeviceID) async throws { check("closeRoom") }
    func listRooms(device: DeviceID) async throws -> RoomsResponse { check("listRooms"); return RoomsResponse(rooms: []) }
    func registerPush(_ registration: PushRegistration) async throws { check("registerPush") }
    func unregisterPush(device: DeviceID) async throws { check("unregisterPush") }
}

// MARK: - MessageStore

/// SQLite 구현(L1)과 같은 의미: (room, seq) 중복 insert 는 throw.
final class FakeMessageStore: MessageStore {
    struct DuplicateKey: Error {}
    private(set) var records: [MessageRecord] = []
    private var roomRecords: [RoomID: RoomRecord] = [:]

    func insert(_ record: MessageRecord) throws {
        guard !records.contains(where: { $0.room == record.room && $0.seq == record.seq }) else { throw DuplicateKey() }
        records.append(record)
    }
    func messages(room: RoomID, after seq: Int64, limit: Int) throws -> [MessageRecord] {
        Array(records.filter { $0.room == room && $0.seq > seq }.sorted { $0.seq < $1.seq }.prefix(limit))
    }
    func upsertRoom(_ room: RoomRecord) throws { roomRecords[room.room] = room }
    func rooms() throws -> [RoomRecord] { roomRecords.values.sorted { $0.displayOrder < $1.displayOrder } }
    func setHalted(room: RoomID, reason: String?) throws {
        var record = roomRecords[room] ?? RoomRecord(room: room, epoch: 0, revision: 0, haltedReason: nil, displayOrder: 0)
        record.haltedReason = reason
        roomRecords[room] = record
    }
}

// MARK: - 조립

/// 한 기기(me)의 동기화 하네스. 스토어·릴레이를 공유한 채 `restart()` 로 새 RoomSyncEngine(재시작 대역)을 만든다.
final class SyncHarness {
    let room: RoomID = "room1"
    let me: DeviceID
    let factory = FakeEngineFactory()
    let store = GuardedStateStore()
    let outbox = InMemoryOutboxStore()
    let cursors = InMemoryCursorStore()
    let messages = FakeMessageStore()
    let relay = FakeRelay()
    var clientSeq = 0
    var configuration = RoomSyncEngine.Configuration()
    var subject = "cf-sub-me"
    private(set) var sync: RoomSyncEngine!

    init(me: DeviceID = "me-iphone-aaaaaa") throws {
        self.me = me
        relay.guardStore = store
        sync = try makeEngine()
    }

    func makeEngine() throws -> RoomSyncEngine {
        try RoomSyncEngine(room: room, identity: me, engineFactory: factory, stateStore: store, outbox: outbox,
                           cursors: cursors, messages: messages, transport: relay, configuration: configuration,
                           enrollmentSubject: subject,
                           makeClientId: { [unowned self] in self.clientSeq += 1; return "\(self.me)-c\(self.clientSeq)" })
    }

    @discardableResult
    func restart() throws -> RoomSyncEngine { sync = try makeEngine(); return sync }

    var engineState: FakeEngineState? { try? store.engineState(room: room) }

    /// 다른 기기의 application 암호문(가짜 엔진이 해독할 수 있는 형식).
    func ciphertext(from sender: DeviceID, clientId: String, text: String) -> Data {
        var plain = Data(text.utf8); plain.append(0)
        return FakeMlsEngine.ciphertextMagic + Framing.encryptInput(room: sender, clientId: clientId, plaintext: plain)
    }
}
