// #599 송신 우선: 동기화 바퀴(방마다 GET 직렬 + 부가 작업)가 `serial` 을 잡고 있을 때 누른 글은, 바퀴가 다음 방·단계 앞에서
// 양보해 곧바로 나간다. 종전에는 FIFO 라 바퀴 전체(오너 iPhone 17방 ≈ 20왕복)가 끝나야 POST 가 나갔다.
import XCTest
import FamilyMLSCore
@testable import FamilyChat

/// 지정한 방의 GET 을 풀어 줄 때까지 붙잡는 전송 — 바퀴 한가운데서 송신을 누르는 순간을 만든다. 모든 GET·POST 를 순서대로 적는다.
final class GatedRelay: InMemoryRelayWrapper {
    private let lock = NSLock()
    private var calls: [String] = []
    private var gateRoom: RoomID?
    private var held: CheckedContinuation<Void, Never>?

    var log: [String] { lock.withLock { calls } }
    var isHeld: Bool { lock.withLock { held != nil } }
    func hold(room: RoomID) { lock.withLock { gateRoom = room } }
    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let c = held; held = nil; gateRoom = nil
            return c
        }
        waiting?.resume()
    }

    override func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage {
        let gated = lock.withLock { () -> Bool in
            calls.append("GET \(room)")
            return gateRoom == room
        }
        if gated { await withCheckedContinuation { c in lock.withLock { held = c } } }
        return try await super.getEvents(room: room, device: device, after: after, limit: limit, ack: ack)
    }

    override func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse {
        lock.withLock { calls.append("POST \(room)") }
        return try await super.postEvent(room: room, post)
    }
}

@MainActor
final class SendPriorityTests: XCTestCase {
    private let roomNames: [RoomID] = ["a", "b", "c", "family"]

    private func readyModel() async -> (AppModel, GatedRelay) {
        let relay = GatedRelay()
        let seeded = roomNames.enumerated().map { RoomRecord(room: $1, epoch: 0, revision: 0, haltedReason: nil, displayOrder: $0) }
        let deps = AppModel.Dependencies(
            engineFactory: MemberFakeFactory(), stateStore: InMemoryStateStore(),
            messageStore: InMemoryMessageStore(seedRooms: seeded),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        let model = AppModel(dependencies: deps)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.syncPreempted, "an idle round runs to the end")
        return (model, relay)
    }

    /// 메인 액터를 넘겨 가며 조건을 기다린다(시간 상한 — 실패면 영원히 매달리지 않는다).
    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting: \(what)") }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testSendDuringARoundIsPostedBeforeTheRemainingRooms() async {
        let (model, relay) = await readyModel()
        let before = relay.log.count
        relay.hold(room: "b")
        let round = Task { await model.refresh() }
        await waitUntil("the round reaches room b") { relay.isHeld }

        let send = Task { await model.send(room: "family", text: "hi") }
        await waitUntil("the bubble is up (send queued behind the round)") { model.outgoing["family"] != nil }
        relay.release()
        guard case .sent? = await send.value else { return XCTFail("\(String(describing: model.lastError))") }
        await round.value

        let log = Array(relay.log[before...])
        guard let post = log.firstIndex(of: "POST family") else { return XCTFail("no POST: \(log)") }
        XCTAssertEqual(Array(log[..<post]), ["GET a", "GET b", "GET family"],
                       "the round yields after the in-flight GET; the send syncs its own room then posts: \(log)")
        XCTAssertFalse(log.contains("GET c"), "room c was left for the next round: \(log)")
        XCTAssertTrue(model.syncPreempted, "the round reports that it yielded (runForeground re-runs without the 4 s wait)")
        XCTAssertEqual(model.messages(room: "family").map(\.record.body), ["hi"])
    }

    func testTheRoundAfterAYieldReadsTheSkippedRooms() async {
        let (model, relay) = await readyModel()
        relay.hold(room: "a")
        let round = Task { await model.refresh() }
        await waitUntil("the round reaches room a") { relay.isHeld }
        let send = Task { await model.send(room: "family", text: "hi") }
        await waitUntil("send queued") { model.outgoing["family"] != nil }
        relay.release()
        _ = await send.value
        await round.value
        XCTAssertTrue(model.syncPreempted)

        let before = relay.log.count
        await model.refresh()
        XCTAssertFalse(model.syncPreempted, "no send waiting: the counter came back to zero and the round ran to the end")
        XCTAssertEqual(relay.log[before...].filter { $0.hasPrefix("GET ") }, roomNames.map { "GET \($0)" },
                       "every room is read again — nothing starves")
    }

    func testSendWithoutARoundInFlightDoesNotMarkAYield() async {
        let (model, _) = await readyModel()
        guard case .sent? = await model.send(room: "family", text: "hi") else { return XCTFail("\(String(describing: model.lastError))") }
        await model.refresh()
        XCTAssertFalse(model.syncPreempted, "a send that ran on its own leaves no waiting count behind")
    }
}
