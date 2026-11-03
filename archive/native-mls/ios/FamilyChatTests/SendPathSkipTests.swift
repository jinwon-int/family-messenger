// #659 송신 경로 단축: 릴레이 방 목록의 `last_seq` 가 "받을 것 없음"을 말하면 ① 바퀴는 보이지 않는 방의 GET 을 건너뛰고
// ② 송신은 직전 GET 없이 바로 POST 한다(왕복 1회). 옛 릴레이(키 없음)는 종전 그대로.
import XCTest
import FamilyMLSCore
@testable import FamilyChat

/// 모든 LIST·GET·POST 를 순서대로 적는 전송.
final class LoggingRelay: InMemoryRelayWrapper {
    private let lock = NSLock()
    private var calls: [String] = []

    var log: [String] { lock.withLock { calls } }
    func reset() { lock.withLock { calls.removeAll() } }

    override func listRooms(device: DeviceID) async throws -> RoomsResponse {
        lock.withLock { calls.append("LIST") }
        return try await super.listRooms(device: device)
    }

    override func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage {
        lock.withLock { calls.append("GET \(room)") }
        return try await super.getEvents(room: room, device: device, after: after, limit: limit, ack: ack)
    }

    override func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse {
        lock.withLock { calls.append("POST \(room)") }
        return try await super.postEvent(room: room, post)
    }
}

@MainActor
final class SendPathSkipTests: XCTestCase {
    private let roomNames: [RoomID] = ["a", "b", "family"]

    /// 방 3개가 기록된 기기. `reportsLastSeq` = 새 릴레이(목록에 `last_seq`) / 옛 릴레이.
    private func readyModel(reportsLastSeq: Bool) async -> (AppModel, LoggingRelay) {
        let relay = LoggingRelay()
        relay.inner.reportsLastSeq = reportsLastSeq
        let seeded = roomNames.enumerated().map { RoomRecord(room: $1, epoch: 0, revision: 0, haltedReason: nil, displayOrder: $0) }
        let deps = AppModel.Dependencies(
            engineFactory: MemberFakeFactory(), stateStore: InMemoryStateStore(),
            messageStore: InMemoryMessageStore(seedRooms: seeded),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        let model = AppModel(dependencies: deps)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        return (model, relay)
    }

    /// 한 번 글을 보내 릴레이가 `family` 를 알게(목록에 올리게) 하고, 그 뒤 바퀴 한 번으로 커서를 릴레이 마지막 seq 에 맞춘다.
    private func primed(reportsLastSeq: Bool) async -> (AppModel, LoggingRelay) {
        let (model, relay) = await readyModel(reportsLastSeq: reportsLastSeq)
        guard case .sent? = await model.send(room: "family", text: "hi") else { XCTFail("\(String(describing: model.lastError))"); return (model, relay) }
        await model.refresh()
        return (model, relay)
    }

    func testRoundSkipsTheGetOfAnUnchangedHiddenRoom() async {
        let (model, relay) = await primed(reportsLastSeq: true)
        relay.reset()
        await model.refresh()
        let log = relay.log
        XCTAssertEqual(log.first, "LIST")
        XCTAssertTrue(log.contains("GET a") && log.contains("GET b"), "rooms the relay does not list carry no hint and are read as before: \(log)")
        XCTAssertFalse(log.contains("GET family"), "family: listed last_seq == persisted cursor → no GET this round: \(log)")
        XCTAssertEqual(model.skippedRoomSyncs, 1)
    }

    func testTheVisibleRoomIsReadEveryRound() async {
        let (model, relay) = await primed(reportsLastSeq: true)
        model.roomShown("family")
        relay.reset()
        await model.refresh()
        XCTAssertTrue(relay.log.contains("GET family"), "the room on screen keeps its per-round GET (typing · read position · mute): \(relay.log)")
        XCTAssertEqual(model.skippedRoomSyncs, 0)
        model.roomHidden("family")
        relay.reset()
        await model.refresh()
        XCTAssertFalse(relay.log.contains("GET family"), "hidden again → skipped: \(relay.log)")
    }

    func testSendPostsWithoutAPreSyncWhenTheHintMatches() async {
        let (model, relay) = await primed(reportsLastSeq: true)
        relay.reset()
        guard case .sent? = await model.send(room: "family", text: "again") else { return XCTFail("\(String(describing: model.lastError))") }
        XCTAssertEqual(relay.log, ["POST family"], "one round trip: no GET before the POST: \(relay.log)")
        XCTAssertEqual(model.messages(room: "family").map(\.record.body), ["hi", "again"])
        guard let line = model.diagnostics.last(where: { $0.contains("send family:") }) else { return XCTFail("no send timing line: \(model.diagnostics)") }
        XCTAssertTrue(line.contains("presync=skip"), line)
        XCTAssertFalse(line.contains("again"), "the diagnostics line never carries the text")
    }

    func testAnOldRelayWithoutLastSeqKeepsTheFormerBehaviour() async {
        let (model, relay) = await primed(reportsLastSeq: false)
        relay.reset()
        await model.refresh()
        XCTAssertTrue(relay.log.contains("GET family"), "no hint → every room is read: \(relay.log)")
        XCTAssertEqual(model.skippedRoomSyncs, 0)
        relay.reset()
        guard case .sent? = await model.send(room: "family", text: "again") else { return XCTFail("\(String(describing: model.lastError))") }
        XCTAssertEqual(relay.log, ["GET family", "POST family"], "sync first, then post — unchanged: \(relay.log)")
        guard let line = model.diagnostics.last(where: { $0.contains("send family:") }) else { return XCTFail("no send timing line") }
        XCTAssertTrue(line.contains("presync=") && !line.contains("presync=skip"), line)
    }

    func testANewEventAfterTheListingIsStillFetched() async {
        let (model, relay) = await primed(reportsLastSeq: true)
        // 목록을 받은 뒤(바퀴 사이) 다른 기기가 글을 올렸다 → 다음 목록의 last_seq 가 커서보다 크다 → GET.
        _ = try? await relay.inner.postEvent(room: "family", EventPost(device: "dad-iphone-9f9f9f", clientId: "dad-1", kind: .application,
                                                                         epoch: 0, bytes: Data("ct:x".utf8)))
        relay.reset()
        await model.refresh()
        XCTAssertTrue(relay.log.contains("GET family"), "a moved room is read: \(relay.log)")
    }
}
