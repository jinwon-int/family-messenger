// App ∥ NSE — 같은 방을 두 프로세스가 처리할 때의 정합(파이널라이저 결정 D4, #271 §4·§8·§12-D 수용 ②).
// "두 프로세스" 대역 = 같은 디렉터리를 연 FileStateStore 두 인스턴스(flock 은 열린 파일마다 따로 — L1 계약 테스트와 같은 방식)
// + 같은 messages.db 를 연 FileSQLiteStore 두 인스턴스. 엔진은 가짜(복호화 횟수를 센다), 릴레이는 FakeRelay 하나를 공유한다.
// 인터리빙은 결정적으로 만든다: 한쪽의 GET 응답을 붙잡아 둔 채 다른 쪽이 끝까지 처리하게 한다.
import XCTest
@testable import FamilyMLSCore

/// GET 응답을 받아 둔 뒤 `release()` 까지 돌려주지 않는 전송(낡은 페이지를 든 프로세스).
final class HeldPageTransport: RelayTransport {
    let base: FakeRelay
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    private var fetched: CheckedContinuation<Void, Never>?
    private var didFetch = false

    init(base: FakeRelay) { self.base = base }

    /// GET 이 응답을 받아 둘 때까지 기다린다.
    func waitUntilFetched() async {
        if didFetch { return }
        await withCheckedContinuation { fetched = $0 }
    }

    func release() {
        released = true
        held?.resume(); held = nil
    }

    func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage {
        let page = try await base.getEvents(room: room, device: device, after: after, limit: limit, ack: ack)
        didFetch = true
        fetched?.resume(); fetched = nil
        if !released { await withCheckedContinuation { held = $0 } }
        return page
    }

    func postKeyPackages(room: RoomID, _ post: KeyPackagePost) async throws -> KeyPackagesResponse { try await base.postKeyPackages(room: room, post) }
    func consumeKeyPackage(room: RoomID, device: DeviceID, target: DeviceID) async throws -> StoredKeyPackage? {
        try await base.consumeKeyPackage(room: room, device: device, target: target)
    }
    func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse { try await base.postEvent(room: room, post) }
    func closeRoom(room: RoomID, device: DeviceID) async throws { try await base.closeRoom(room: room, device: device) }
    func listRooms(device: DeviceID) async throws -> RoomsResponse { try await base.listRooms(device: device) }
    func registerPush(_ registration: PushRegistration) async throws { try await base.registerPush(registration) }
    func unregisterPush(device: DeviceID) async throws { try await base.unregisterPush(device: device) }
}

/// setCursor 를 잃는 커서 저장소 — "상태는 커밋했고 커서를 쓰기 전에 프로세스가 죽었다"(NSE 시간·메모리 초과) 대역.
final class LosingCursorStore: CursorStore {
    func cursor(room: RoomID) throws -> Int64 { 0 }
    func setCursor(room: RoomID, seq: Int64) throws {}
}

final class SyncCrossProcessTests: XCTestCase {
    private let room: RoomID = "room1"
    private let me: DeviceID = "me-iphone-aaaaaa"
    private let alice: DeviceID = "alice-pc"
    private var dir: URL!
    private let relay = FakeRelay()
    private let factory = FakeEngineFactory()

    /// 한 "프로세스": 자기 FileStateStore·FileSQLiteStore 인스턴스(같은 디렉터리)와 자기 RoomSyncEngine.
    struct Process {
        let state: FileStateStore
        let db: FileSQLiteStore
        let sync: RoomSyncEngine
    }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fc-xproc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let seedStore = try FileStateStore(directory: dir.appendingPathComponent("mls"), sealer: nil)
        try seedStore.withExclusive(room: room, timeout: 1) { try $0.save(FakeEngineState.joined([alice, me]).bytes) }
        let seedDB = try FileSQLiteStore(directory: dir)
        try seedDB.upsertRoom(RoomRecord(room: room, epoch: 1, revision: 1, haltedReason: nil, displayOrder: 0))
        relay.epoch = 1
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func process(_ decryptedBy: MessageRecord.DecryptedBy, transport: RelayTransport? = nil,
                         cursors: CursorStore? = nil) throws -> Process {
        let state = try FileStateStore(directory: dir.appendingPathComponent("mls"), sealer: nil)
        let db = try FileSQLiteStore(directory: dir)
        var configuration = RoomSyncEngine.Configuration()
        configuration.decryptedBy = decryptedBy
        configuration.lockTimeout = 2
        let sync = try RoomSyncEngine(room: room, identity: me, engineFactory: factory, stateStore: state, outbox: db,
                                      cursors: cursors ?? db, messages: db, transport: transport ?? relay, configuration: configuration)
        return Process(state: state, db: db, sync: sync)
    }

    @discardableResult
    private func aliceSends(_ texts: [String]) -> [Int64] {
        texts.map { text in
            var plain = Data(text.utf8); plain.append(0)
            let bytes = FakeMlsEngine.ciphertextMagic + Framing.encryptInput(room: alice, clientId: alice, plaintext: plain)
            return relay.inject(device: alice, kind: .application, bytes: bytes)
        }
    }

    private func texts(_ db: FileSQLiteStore) throws -> [String] {
        try db.messages(room: room, after: 0, limit: 100).map(\.body)
    }

    /// NSE 가 낡은 페이지(커서 0 기준)를 든 사이 App 이 같은 페이지를 끝까지 처리 → NSE 는 아무것도 다시 복호화하지 않고
    /// 커서도 되돌리지 않는다(D4 a·c).
    func testStalePageAfterOtherProcessFinishedIsNotDecryptedAgain() async throws {
        aliceSends(["하나", "둘", "셋"])
        let held = HeldPageTransport(base: relay)
        let nse = try process(.nse, transport: held)
        let app = try process(.app)

        let nseTask = Task { try await nse.sync.syncOnce() }
        await held.waitUntilFetched()
        let appPass = try await app.sync.syncOnce()
        XCTAssertEqual(appPass.inserted, [1, 2, 3])
        XCTAssertEqual(factory.log.count(.decrypt), 3)

        held.release()
        let nsePass = try await nseTask.value
        XCTAssertEqual(nsePass.inserted, [], "이미 처리된 seq 는 다시 넣지 않는다")
        XCTAssertEqual(nsePass.rejected, [], "재복호화 거부도 없다 — 시도 자체가 없다")
        XCTAssertEqual(factory.log.count(.decrypt), 3, "중복 복호화 0")
        XCTAssertEqual(nsePass.cursor, 3)
        XCTAssertEqual(try app.db.cursor(room: room), 3, "커서는 단조")
        XCTAssertEqual(try texts(app.db), ["하나", "둘", "셋"])
        XCTAssertEqual(try app.db.messages(room: room, after: 0, limit: 10).map(\.decryptedBy), [.app, .app, .app])
    }

    /// NSE 가 상태를 커밋하고 커서를 쓰기 전에 죽었다(커서 유실) → App 은 커서 0 에서 같은 페이지를 받지만
    /// MessageStore 에 이미 있는 seq 는 복호화하지 않는다(D4 b). 그 뒤 새 메시지는 정상 복호화(상태 손상 없음).
    func testRowsStoredByAProcessThatDiedBeforeItsCursorAreNotDecryptedAgain() async throws {
        aliceSends(["안녕", "잘 지내?"])
        let nse = try process(.nse, cursors: LosingCursorStore())
        let nsePass = try await nse.sync.syncOnce()
        XCTAssertEqual(nsePass.inserted, [1, 2])
        XCTAssertEqual(factory.log.count(.decrypt), 2)

        let app = try process(.app)
        XCTAssertEqual(try app.db.cursor(room: room), 0, "NSE 의 커서는 쓰이지 않았다")
        let appPass = try await app.sync.syncOnce()
        XCTAssertEqual(appPass.inserted, [])
        XCTAssertEqual(appPass.rejected, [])
        XCTAssertEqual(factory.log.count(.decrypt), 2, "중복 복호화 0")
        XCTAssertEqual(try app.db.cursor(room: room), 2)
        XCTAssertEqual(try app.db.messages(room: room, after: 0, limit: 10).map(\.decryptedBy), [.nse, .nse])

        aliceSends(["새 메시지"])
        let next = try await app.sync.syncOnce()
        XCTAssertEqual(next.inserted, [3])
        XCTAssertEqual(try texts(app.db), ["안녕", "잘 지내?", "새 메시지"])
        // 수신 ratchet(가짜 엔진의 receiveGeneration) = 정확히 복호화한 수 — 같은 메시지를 두 번 소비하지 않았다.
        let state = try app.state.withExclusive(room: room, timeout: 1) { try $0.load() }.map(FakeEngineState.decode)
        XCTAssertEqual(state?.receiveGeneration, 3)
    }

    /// 두 프로세스가 번갈아(서로의 커서 쓰기 전후로) 1,000건을 나눠 처리해도 행·커서·generation 이 일관된다.
    func testAlternatingProcessesKeepMonotonicCursorAndGeneration() async throws {
        let app = try process(.app)
        let nse = try process(.nse)
        var expected: [String] = []
        var lastGeneration: UInt64 = try app.state.generation(room: room)
        for round in 0..<200 {
            let batch = (0..<5).map { "m\(round)-\($0)" }
            aliceSends(batch)
            expected += batch
            let worker = round % 3 == 0 ? nse : app
            let other = round % 3 == 0 ? app : nse
            _ = try await worker.sync.syncAll()
            _ = try await other.sync.syncAll()   // 할 일 없음 — 다시 복호화하지 않아야 한다
            let generation = try app.state.generation(room: room)
            XCTAssertGreaterThan(generation, lastGeneration)
            lastGeneration = generation
        }
        XCTAssertEqual(try app.db.messages(room: room, after: 0, limit: 2000).map(\.body), expected)
        XCTAssertEqual(factory.log.count(.decrypt), expected.count, "중복 복호화 0")
        XCTAssertEqual(try nse.db.cursor(room: room), Int64(expected.count))
        XCTAssertEqual(try app.db.messages(room: room, after: 0, limit: 2000).filter { $0.kind == .undecryptable }, [])
    }
}
