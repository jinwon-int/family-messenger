// #701 백그라운드 전환: App Group 의 messages.db 를 읽는 중에 앱이 정지되면 RunningBoard 가 `0xdead10cc` 로 죽인다(TestFlight 7건 —
// 폴링 바퀴의 outbox·타임라인 읽기). 백그라운드에서는 새 바퀴·재전송·화면의 DB 읽기를 하지 않고, 이미 들어간 일은 끝까지 기다린다.
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class BackgroundSuspendTests: XCTestCase {
    private let roomNames: [RoomID] = ["a", "b", "c", "family"]

    private func readyModel() async -> (AppModel, GatedRelay, InMemoryMessageStore) {
        let relay = GatedRelay()
        let seeded = roomNames.enumerated().map { RoomRecord(room: $1, epoch: 0, revision: 0, haltedReason: nil, displayOrder: $0) }
        let store = InMemoryMessageStore(seedRooms: seeded)
        let deps = AppModel.Dependencies(
            engineFactory: MemberFakeFactory(), stateStore: InMemoryStateStore(),
            messageStore: store,
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        let model = AppModel(dependencies: deps)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        return (model, relay, store)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting: \(what)") }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func record(_ room: RoomID, _ seq: Int64, _ body: String) -> MessageRecord {
        MessageRecord(room: room, seq: seq, senderDevice: "dad-iphone-d4e5f6", clientId: "c\(seq)", kind: .text,
                      body: body, attachment: nil, receivedAt: Date(), decryptedBy: .app)
    }

    private final class Flag { var value = false }

    func testNoRoundRunsInTheBackgroundAndTheFirstActiveRoundSyncsAgain() async {
        let (model, relay, _) = await readyModel()
        await model.backgrounded()
        XCTAssertTrue(model.suspended)
        let before = relay.log.count
        await model.refresh()
        XCTAssertEqual(relay.log.count, before, "no GET/POST while in the background: \(relay.log.suffix(from: before))")

        await model.foregrounded()
        XCTAssertFalse(model.suspended)
        XCTAssertGreaterThan(relay.log.count, before, "coming back runs a round at once")
    }

    func testBackgroundWaitsForTheRequestInFlightThenCutsTheRound() async {
        let (model, relay, _) = await readyModel()
        relay.hold(room: "b")
        let round = Task { await model.refresh() }
        await waitUntil("the round reaches room b") { relay.isHeld }

        let drained = Flag()
        let drain = Task { await model.backgrounded(); drained.value = true }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(drained.value, "the request in flight is not cancelled — the drain waits for it (beginBackgroundTask time)")
        let mark = relay.log.count
        relay.release()
        await drain.value
        await round.value

        XCTAssertTrue(drained.value)
        let after = relay.log.suffix(from: mark)
        XCTAssertFalse(after.contains { $0 == "GET c" || $0 == "GET family" }, "rooms after b wait for the next active round: \(after)")
        XCTAssertFalse(model.syncPreempted, "a background cut is not a send preemption — runForeground must not spin")
    }

    func testTimelineIsNotReadFromTheStoreInTheBackground() async throws {
        let (model, _, store) = await readyModel()
        try store.insert(record("family", 1, "before"))
        XCTAssertEqual(model.messages(room: "family").map(\.record.body), ["before"])

        await model.backgrounded()
        try store.insert(record("family", 2, "while away"))
        XCTAssertEqual(model.messages(room: "family").map(\.record.body), ["before"], "the last read, without touching the database")
        XCTAssertEqual(model.messages(room: "a").map(\.record.body), [], "a room never read stays empty until active")

        await model.foregrounded()
        XCTAssertEqual(model.messages(room: "family").map(\.record.body), ["before", "while away"])
    }
}
