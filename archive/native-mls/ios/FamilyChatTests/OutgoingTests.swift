// 보내는 글(오너 요청 build 31): 누르는 즉시 목록에 오르고, 릴레이가 받으면 실제 기록이 잇고, 보관·실패는 말풍선 아래 상태로.
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class OutgoingTests: XCTestCase {
    private func readyModel(joined: Bool = true) async -> (AppModel, InMemoryRelay) {
        let relay = InMemoryRelay()
        let deps = AppModel.Dependencies(
            engineFactory: joined ? AnyFactory(MemberFakeFactory()) : AnyFactory(FakeFactory()),
            stateStore: InMemoryStateStore(),
            messageStore: InMemoryMessageStore(seedRooms: joined ? [] : [RoomRecord(room: "family", epoch: 0, revision: 0, haltedReason: nil, displayOrder: 0)]),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        let model = AppModel(dependencies: deps)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        return (model, relay)
    }

    func testDeliveredSendLeavesOnlyTheRecord() async {
        let (model, _) = await readyModel()
        guard case .sent? = await model.send(room: "family", text: "hi") else { return XCTFail("\(String(describing: model.lastError))") }
        XCTAssertNil(model.outgoing["family"], "delivered: nothing left to show as outgoing")
        let items = model.messages(room: "family")
        XCTAssertEqual(items.map(\.record.body), ["hi"])
        XCTAssertNil(items[0].outgoing)
        XCTAssertGreaterThan(items[0].id, 0)
    }

    /// 릴레이가 끊긴 채 보낸 글(outbox 에 들어가기 전 실패): 「연결되면 보냅니다」로 보이다가, 연결이 돌아온 동기화 뒤 자동으로 나간다.
    func testUnreachableSendIsShownAsQueuedAndResentWhenBack() async throws {
        let (model, relay) = await readyModel()
        try await relay.stop()
        let outcome = await model.send(room: "family", text: "later")
        XCTAssertNil(outcome, "the sync before the POST fails — nothing reached the outbox")
        let shown = model.messages(room: "family")
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].record.body, "later")
        XCTAssertEqual(shown[0].outgoing, .queued)
        XCTAssertLessThan(shown[0].id, -2, "outgoing ids never collide with the view's sentinel ids")
        XCTAssertEqual(shown[0].record.senderDevice, model.deviceId)
        XCTAssertNil(model.lastError, "the bubble carries the state; no banner text")
        XCTAssertTrue(model.reconnecting)

        await model.refresh()
        XCTAssertEqual(model.messages(room: "family")[0].outgoing, .queued, "still down: nothing resent")

        try await relay.start()
        await model.refresh()
        XCTAssertFalse(model.reconnecting)
        XCTAssertNil(model.outgoing["family"], "resent after the first successful sync")
        let after = model.messages(room: "family")
        XCTAssertEqual(after.map(\.record.body), ["later"], "the record replaces the outgoing item, no duplicate")
        XCTAssertNil(after[0].outgoing)
        XCTAssertGreaterThan(after[0].id, 0)
    }

    func testFailedSendShowsTheReasonAndCanBeRetried() async {
        let (model, _) = await readyModel(joined: false)
        let outcome = await model.send(room: "family", text: "too early")
        XCTAssertNil(outcome)
        var items = model.messages(room: "family")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].outgoing, .failed(Strings.notJoined))
        XCTAssertNil(model.lastError, "the reason lives under the bubble")

        await model.retry(outgoingId: items[0].id, room: "family")
        items = model.messages(room: "family")
        XCTAssertEqual(items.count, 1, "a retry replaces the failed item, it does not pile up")
        XCTAssertEqual(items[0].outgoing, .failed(Strings.notJoined))
    }

    func testTwoOutgoingMessagesKeepOrderAndDistinctIds() async throws {
        let (model, relay) = await readyModel()
        try await relay.stop()
        _ = await model.send(room: "family", text: "one")
        _ = await model.send(room: "family", text: "two")
        let items = model.messages(room: "family")
        XCTAssertEqual(items.map(\.record.body), ["one", "two"])
        XCTAssertNotEqual(items[0].id, items[1].id)
        XCTAssertTrue(items.allSatisfy { $0.outgoing == .queued }, "\(items.map(\.outgoing))")
        try await relay.start()
        await model.refresh()
        XCTAssertEqual(model.messages(room: "family").map(\.record.body), ["one", "two"], "resent in order")
        XCTAssertNil(model.outgoing["family"])
    }
}

/// 두 팩토리를 한 타입으로(테스트 편의).
private struct AnyFactory: MlsEngineFactory {
    let create: (DeviceID) throws -> MlsEngine
    let importState: (DeviceID, Data) throws -> MlsEngine
    init<F: MlsEngineFactory>(_ inner: F) {
        create = { try inner.create(identity: $0) }
        importState = { try inner.importState(identity: $0, bytes: $1) }
    }
    func create(identity: DeviceID) throws -> MlsEngine { try create(identity) }
    func importState(identity: DeviceID, bytes: Data) throws -> MlsEngine { try importState(identity, bytes) }
}
