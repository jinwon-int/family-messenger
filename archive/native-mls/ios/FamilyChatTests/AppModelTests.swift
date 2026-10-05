// 상태기계 테스트 — 가짜 엔진 + Core InMemory 스토어 (xcframework 불필요).
import XCTest
import FamilyMLSCore
@testable import FamilyChat

final class FakeEngine: MlsEngine {
    let identity: DeviceID
    var state: Data
    var rejectNext: String?
    init(identity: DeviceID, state: Data = Data("s0".utf8)) { self.identity = identity; self.state = state }
    func dispatch(_ method: EngineMethod, _ input: Data) throws -> Data {
        if let r = rejectNext { rejectNext = nil; throw EngineError.rejected(r) }
        state.append(1)
        return Data("ct:".utf8) + input
    }
    func exportState() throws -> Data { state }
    func publicKey() throws -> Data { Data(repeating: 0xab, count: 32) }
    func fingerprint() throws -> String { String(repeating: "f", count: 64) }
    func hasPending() throws -> Bool { false }
}

struct FakeFactory: MlsEngineFactory {
    var created: [DeviceID] = []
    func create(identity: DeviceID) throws -> MlsEngine { FakeEngine(identity: identity) }
    func importState(identity: DeviceID, bytes: Data) throws -> MlsEngine { FakeEngine(identity: identity, state: bytes) }
}

@MainActor
final class AppModelTests: XCTestCase {
    func makeModel(rooms: [RoomRecord] = [], format: UInt32 = 2) -> (AppModel, InMemoryOutboxStore, InMemoryStateStore) {
        let outbox = InMemoryOutboxStore()
        let state = InMemoryStateStore()
        let deps = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: state, messageStore: InMemoryMessageStore(seedRooms: rooms),
            outbox: outbox, cursors: InMemoryCursorStore(),
            identityProvider: { "owner-iphone-abc123" }, expectedDecryptFormat: { format })
        return (AppModel(dependencies: deps), outbox, state)
    }

    func testBootstrapCreatesIdentityAndPersistsState() async throws {
        let (model, _, state) = makeModel()
        await model.bootstrap()
        XCTAssertEqual(model.phase, .needsLogin)
        XCTAssertEqual(model.deviceId, "owner-iphone-abc123")
        XCTAssertEqual(model.fingerprint.count, 64)
        XCTAssertEqual(try state.generation(room: Strings.identityRoom), 1, "fresh identity is persisted once")
        XCTAssertTrue(model.registrationJSON().contains("\"signing_key\" : \"abab"))
    }

    func testDecryptFormatMismatchIsFatal() async {
        let (model, _, _) = makeModel(format: 3)
        await model.bootstrap()
        XCTAssertEqual(model.phase, .fatal(Strings.decryptFormatMismatch))
    }

    func testLoginEnrollReadyAndHaltedRoomIsSurfaced() async {
        let halted = RoomRecord(room: "family", epoch: 1, revision: 1, haltedReason: "commit_refused", displayOrder: 0)
        let (model, _, _) = makeModel(rooms: [halted])
        await model.bootstrap()
        model.login(.accessCookie("jwt"))
        XCTAssertEqual(model.phase, .needsEnrollment)
        model.markEnrolled()
        XCTAssertEqual(model.phase, .halted("commit_refused"), "halt survives restart via MessageStore")
    }

    func testSendEncryptsPersistsAndQueuesExactBytes() async throws {
        let room = RoomRecord(room: "family", epoch: 1, revision: 1, haltedReason: nil, displayOrder: 0)
        let (model, outbox, state) = makeModel(rooms: [room])
        await model.bootstrap(); model.login(.bearer("t")); model.markEnrolled()
        XCTAssertEqual(model.phase, .ready)
        model.send(room: "family", text: "안녕")
        let pending = try outbox.pending(room: "family")
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending[0].clientId.hasPrefix("owner-iphone-abc123:"))
        XCTAssertEqual(pending[0].bytes.prefix(3), Data("ct:".utf8))
        XCTAssertEqual(try state.generation(room: "family"), 1, "state saved inside the exclusive transaction")
        XCTAssertNil(model.lastError)
    }

    func testRejectedSendLeavesNoOutboxEntry() async throws {
        let room = RoomRecord(room: "family", epoch: 1, revision: 1, haltedReason: nil, displayOrder: 0)
        let (model, outbox, state) = makeModel(rooms: [room])
        await model.bootstrap(); model.login(.bearer("t")); model.markEnrolled()
        (model.engineForUI() as? FakeEngine)?.rejectNext = "device retired"
        model.send(room: "family", text: "x")
        XCTAssertEqual(try outbox.pending(room: "family").count, 0)
        XCTAssertEqual(try state.generation(room: "family"), 0, "disk unchanged after rejection")
        XCTAssertEqual(model.lastError, Strings.sendRejected("device retired"))
    }

    func testLogoutKeepsIdentity() async {
        let (model, _, _) = makeModel()
        await model.bootstrap(); model.login(.bearer("t"))
        let fp = model.fingerprint
        model.logout()
        XCTAssertEqual(model.phase, .needsLogin)
        XCTAssertEqual(model.fingerprint, fp)
    }
}
