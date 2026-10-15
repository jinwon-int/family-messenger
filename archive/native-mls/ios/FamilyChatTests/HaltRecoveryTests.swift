// ⛔ 정지 해제(`AppModel.prepareRejoin`) + 안내 문구(Strings+Halt) — 가짜 엔진(FakeFactory, AppModelTests.swift) + 메모리 릴레이.
// 파일 저장소의 실제 삭제는 Core `FileStateRemovalTests` 가 덮는다; 여기서는 상태기계 순서(폐기 → 커서 0 → outbox reconciled → 키 패키지 게시)를 본다.
import XCTest
import FamilyMLSCore
@testable import FamilyChat

/// 공개 API 만으로 `RoomStateRemoving` 을 흉내 낸다: 방마다 `InMemoryStateStore` 하나, 삭제 = 그 방의 스토어를 새것으로 교체.
final class RemovableInMemoryStateStore: MlsStateStore, RoomStateRemoving {
    private var stores: [RoomID: InMemoryStateStore] = [:]
    private(set) var removed: [RoomID] = []
    private let lock = NSLock()

    private func store(_ room: RoomID) -> InMemoryStateStore {
        lock.lock(); defer { lock.unlock() }
        if let s = stores[room] { return s }
        let s = InMemoryStateStore(); stores[room] = s; return s
    }

    func withExclusive<T>(room: RoomID, timeout: TimeInterval, _ body: (StateTransaction) throws -> T) throws -> T {
        try store(room).withExclusive(room: room, timeout: timeout, body)
    }

    func generation(room: RoomID) throws -> UInt64 { try store(room).generation(room: room) }

    func removeState(room: RoomID, timeout: TimeInterval) throws {
        lock.lock(); defer { lock.unlock() }
        stores[room] = nil
        removed.append(room)
    }
}

@MainActor
final class HaltRecoveryTests: XCTestCase {
    private func makeModel(stateStore: MlsStateStore, rooms: [RoomRecord], transport: RelayTransport = InMemoryRelay())
        -> (AppModel, InMemoryOutboxStore, InMemoryCursorStore) {
        let outbox = InMemoryOutboxStore()
        let cursors = InMemoryCursorStore()
        let deps = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: stateStore, messageStore: InMemoryMessageStore(seedRooms: rooms),
            outbox: outbox, cursors: cursors,
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 },
            makeTransport: { _ in transport })
        return (AppModel(dependencies: deps), outbox, cursors)
    }

    private static let halted = RoomRecord(room: "family", epoch: 7, revision: 3, haltedReason: SyncHaltReason.historyGap, displayOrder: 0)

    func testPrepareRejoinDiscardsRoomStateResetsCursorAndPublishesKeyPackage() async throws {
        let state = RemovableInMemoryStateStore()
        try state.withExclusive(room: "family", timeout: 1) { try $0.save(Data("old-group".utf8)) }
        let relay = InMemoryRelay()
        let (model, outbox, cursors) = makeModel(stateStore: state, rooms: [Self.halted], transport: relay)
        try cursors.setCursor(room: "family", seq: 42)
        try outbox.enqueue(OutboxEntry(room: "family", clientId: "mom-iphone-a1b2c3-stale", kind: "application", epoch: 7,
                                       bytes: Data("ct".utf8), status: .pending, createdAt: Date()))
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertEqual(model.phase, .halted(SyncHaltReason.historyGap))
        let fingerprint = model.fingerprint
        XCTAssertEqual(model.haltedRooms.map(\.room), ["family"])

        let outcome = try await model.prepareRejoin(room: "family")
        XCTAssertEqual(outcome, .prepared)
        XCTAssertEqual(state.removed, ["family"], "only the halted room's state is discarded")
        XCTAssertEqual(model.phase, .ready, "no halted room is left")
        XCTAssertEqual(model.rooms.first?.haltedReason, nil)
        XCTAssertEqual(model.rooms.first?.epoch, 0)
        XCTAssertEqual(try cursors.cursor(room: "family"), 0, "reads start over after the re-invite")
        XCTAssertTrue(try outbox.pending(room: "family").isEmpty, "bytes from the old epoch are never retried")
        XCTAssertEqual(model.fingerprint, fingerprint, "the identity slot (signing key) is untouched")
        XCTAssertEqual(try state.generation(room: Strings.identityRoom), 1)
        let listing = try await relay.listRooms(device: model.deviceId)
        XCTAssertEqual(listing.rooms.first?.keypackagesOutstanding, 1, "a fresh key package is waiting for the inviter")
        XCTAssertEqual(try state.generation(room: "family"), 1, "the room state was recreated from the seed for the key package")
    }

    func testPrepareRejoinWithoutASessionClearsTheHaltButCannotPublish() async throws {
        let state = RemovableInMemoryStateStore()
        let (model, _, _) = makeModel(stateStore: state, rooms: [Self.halted])
        await model.bootstrap()
        XCTAssertEqual(model.phase, .needsLogin)
        let outcome = try await model.prepareRejoin(room: "family")
        guard case .preparedWithoutPublish = outcome else { return XCTFail("expected preparedWithoutPublish, got \(outcome)") }
        XCTAssertEqual(state.removed, ["family"])
        XCTAssertNil(model.rooms.first?.haltedReason)
        XCTAssertEqual(model.phase, .needsLogin, "the phase is not forced to ready without a session")
    }

    func testPrepareRejoinRefusesHealthyRoomsAndTheIdentitySlot() async {
        let (model, _, _) = makeModel(stateStore: RemovableInMemoryStateStore(),
                                      rooms: [RoomRecord(room: "family", epoch: 1, revision: 1, haltedReason: nil, displayOrder: 0)])
        await model.bootstrap()
        do { _ = try await model.prepareRejoin(room: "family"); XCTFail("healthy room must not be reset") }
        catch { XCTAssertEqual(error as? AppModel.RejoinError, .notHalted) }
        do { _ = try await model.prepareRejoin(room: Strings.identityRoom); XCTFail("identity slot is never removable here") }
        catch { XCTAssertEqual(error as? AppModel.RejoinError, .unsupported) }
    }

    func testPrepareRejoinIsUnsupportedWhenTheStoreCannotRemoveState() async {
        let (model, _, _) = makeModel(stateStore: InMemoryStateStore(), rooms: [Self.halted])
        await model.bootstrap()
        do { _ = try await model.prepareRejoin(room: "family"); XCTFail() }
        catch { XCTAssertEqual(error as? AppModel.RejoinError, .unsupported) }
        XCTAssertEqual(model.rooms.first?.haltedReason, SyncHaltReason.historyGap, "nothing changed")
    }

    // MARK: 문구

    func testHaltGuidanceCoversEveryKnownReason() {
        XCTAssertTrue(Strings.haltGuidance(SyncHaltReason.historyGap).canPrepareRejoin)
        XCTAssertTrue(Strings.haltGuidance(SyncHaltReason.removedFromRoom).canPrepareRejoin)
        XCTAssertFalse(Strings.haltGuidance(SyncHaltReason.roomClosed).canPrepareRejoin, "a closed room cannot be rejoined")
        for reason in CommitRefusalReason.allCases {
            let g = Strings.haltGuidance(reason.rawValue)
            XCTAssertTrue(g.what.contains("규칙"), reason.rawValue)
            XCTAssertTrue(g.next.contains("운영자"), reason.rawValue)
            XCTAssertFalse(g.what.contains("알 수 없는"), "refusal tokens are recognised: \(reason.rawValue)")
        }
        XCTAssertTrue(Strings.haltGuidance("something_new").what.contains("something_new"))
    }

    func testHaltReportCarriesRoomDeviceAndReasonOnly() {
        let report = Strings.haltReport(room: "family", device: "mom-iphone-a1b2c3", reason: "outer_inner_mismatch", at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(report.contains("대화방: family"))
        XCTAssertTrue(report.contains("기기: mom-iphone-a1b2c3"))
        XCTAssertTrue(report.contains("사유: outer_inner_mismatch"))
        XCTAssertTrue(report.contains("1970-01-01T00:00:00Z"))
    }
}
