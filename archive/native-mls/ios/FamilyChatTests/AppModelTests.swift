// 상태기계 테스트 — 가짜 엔진 + Core InMemory 스토어 + 메모리/거부 전송 (xcframework 불필요).
// 실 엔진·파일 저장소를 쓰는 통합 시나리오는 IntegrationTests.swift.
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
    func create(identity: DeviceID) throws -> MlsEngine { FakeEngine(identity: identity) }
    func importState(identity: DeviceID, bytes: Data) throws -> MlsEngine { FakeEngine(identity: identity, state: bytes) }
}

/// listRooms 만 정해진 오류로 거부하는 전송(나머지는 메모리 릴레이).
final class RefusingRelay: InMemoryRelayWrapper {
    let error: Error
    init(_ error: Error) { self.error = error }
    override func listRooms(device: DeviceID) async throws -> RoomsResponse { throw error }
}

class InMemoryRelayWrapper: RelayTransport {
    let inner = InMemoryRelay()
    func postKeyPackages(room: RoomID, _ post: KeyPackagePost) async throws -> KeyPackagesResponse { try await inner.postKeyPackages(room: room, post) }
    func consumeKeyPackage(room: RoomID, device: DeviceID, target: DeviceID) async throws -> StoredKeyPackage? { try await inner.consumeKeyPackage(room: room, device: device, target: target) }
    func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse { try await inner.postEvent(room: room, post) }
    func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage {
        try await inner.getEvents(room: room, device: device, after: after, limit: limit, ack: ack)
    }
    func closeRoom(room: RoomID, device: DeviceID) async throws { try await inner.closeRoom(room: room, device: device) }
    func listRooms(device: DeviceID) async throws -> RoomsResponse { try await inner.listRooms(device: device) }
    func registerPush(_ registration: PushRegistration) async throws { try await inner.registerPush(registration) }
    func unregisterPush(device: DeviceID) async throws { try await inner.unregisterPush(device: device) }
}

@MainActor
final class AppModelTests: XCTestCase {
    func makeModel(rooms: [RoomRecord] = [], format: UInt32 = 2, transport: RelayTransport? = InMemoryRelay())
        -> (AppModel, InMemoryStateStore) {
        let state = InMemoryStateStore()
        let deps = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: state, messageStore: InMemoryMessageStore(seedRooms: rooms),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "owner-iphone-abc123" }, expectedDecryptFormat: { format },
            makeTransport: { _ in transport })
        return (AppModel(dependencies: deps), state)
    }

    func testBootstrapCreatesIdentityAndPersistsState() async throws {
        let (model, state) = makeModel()
        await model.bootstrap()
        XCTAssertEqual(model.phase, .needsLogin)
        XCTAssertEqual(model.deviceId, "owner-iphone-abc123")
        XCTAssertEqual(model.fingerprint.count, 64)
        XCTAssertEqual(try state.generation(room: Strings.identityRoom), 1, "fresh identity is persisted once")
        let json = model.registrationJSON()
        XCTAssertTrue(json.contains("\"signing_key\" : \"abab"), json)
        XCTAssertTrue(json.contains("\"actor\" : \"owner\""), json)
    }

    func testDecryptFormatMismatchIsFatal() async {
        let (model, _) = makeModel(format: 3)
        await model.bootstrap()
        XCTAssertEqual(model.phase, .fatal(Strings.decryptFormatMismatch))
    }

    func testStartupFailureIsFatalWithReason() async {
        var deps = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: InMemoryStateStore(), messageStore: InMemoryMessageStore(),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "owner-iphone-abc123" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in nil })
        deps.startupFailure = "keychain"
        let failing = AppModel(dependencies: deps)
        await failing.bootstrap()
        XCTAssertEqual(failing.phase, .fatal("keychain"))
    }

    func testLoginWithoutRelayURLStaysOnLogin() async {
        let (model, _) = makeModel(transport: nil)
        await model.bootstrap()
        model.login(.accessCookie("jwt"))
        XCTAssertEqual(model.phase, .needsLogin)
        XCTAssertEqual(model.lastError, Strings.relayNotConfigured)
    }

    func testRefreshReachesReadyAndHaltedRoomIsSurfaced() async {
        let halted = RoomRecord(room: "family", epoch: 1, revision: 1, haltedReason: "commit_refused", displayOrder: 0)
        let (model, _) = makeModel(rooms: [halted])
        await model.bootstrap()
        model.login(.accessCookie("jwt"))
        XCTAssertEqual(model.phase, .needsEnrollment)
        await model.refresh()
        XCTAssertEqual(model.phase, .halted("commit_refused"), "halt survives restart via MessageStore")
    }

    func testRefreshWithNoRoomsIsReady() async {
        let (model, _) = makeModel()
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.lastError)
    }

    func testUnregisteredDeviceWaitsForOperator() async {
        let (model, _) = makeModel(transport: RefusingRelay(RelayError.refused(code: "device_subject_mismatch", status: 403)))
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.phase, .needsEnrollment)
        XCTAssertFalse(model.registrationJSON().isEmpty)
    }

    func testExpiredSessionReturnsToLogin() async {
        let (model, _) = makeModel(transport: RefusingRelay(RelayError.unauthorized))
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.phase, .needsLogin)
        XCTAssertNil(model.credential)
        XCTAssertEqual(model.lastError, Strings.sessionExpired)
    }

    func testRelayWithoutRoomListingStillSyncsKnownRooms() async {
        let known = RoomRecord(room: "family", epoch: 0, revision: 0, haltedReason: nil, displayOrder: 0)
        let (model, _) = makeModel(rooms: [known], transport: RefusingRelay(RelayError.refused(code: "http_404", status: 404)))
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.phase, .ready, "404 on /v2/rooms = old relay; known rooms still sync (\(model.lastError ?? "-"))")
    }

    func testSendBeforeReadyDoesNothing() async {
        let (model, _) = makeModel()
        await model.bootstrap(); model.login(.bearer("t"))
        let outcome = await model.send(room: "family", text: "x")
        XCTAssertNil(outcome)
    }

    func testSeededFactoryStartsRoomsFromTheIdentitySlot() async throws {
        let seed = Data("identity-slot".utf8)
        let factory = SeededEngineFactory(base: FakeFactory()) { seed }
        let room = try factory.create(identity: "owner-iphone-abc123") as? FakeEngine
        XCTAssertEqual(room?.state, seed, "a new room state is the identity slot, not a fresh identity")
    }

    func testLogoutKeepsIdentity() async {
        let (model, _) = makeModel()
        await model.bootstrap(); model.login(.bearer("t"))
        let fp = model.fingerprint
        model.logout()
        XCTAssertEqual(model.phase, .needsLogin)
        XCTAssertEqual(model.fingerprint, fp)
    }
}
