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

    // MARK: - #497 B 송신 신뢰성

    /// 504: 릴레이는 저장했는데 응답을 잃었다. 같은 바이트로 다시 보내 `200 duplicate` — 릴레이에 **한 번만** 저장되고 말풍선은 실제 기록이 잇는다.
    /// 종전에는 거절이 엔진 밖으로 던져져 「연결되면 보냅니다」(clientId 없음)가 됐고, outbox 재전송 + 재암호화 재전송으로 두 번 저장됐다.
    func testGatewayTimeoutAfterStoringSendsOnce() async {
        let (model, relay) = await readyModel()
        relay.failNextPosts([.refused(code: "gateway_timeout", status: 504)], afterStoring: true)
        guard case .queued? = await model.send(room: "family", text: "photo") else { return XCTFail("\(String(describing: model.lastError))") }
        XCTAssertEqual(model.messages(room: "family").last?.outgoing, .queued)

        await model.refresh()
        XCTAssertEqual(relay.applicationEvents(room: "family"), 1, "stored once: the same bytes came back as a duplicate, no re-encryption")
        XCTAssertNil(model.outgoing["family"])
        XCTAssertEqual(model.messages(room: "family").map(\.record.body), ["photo"], "the record replaces the bubble, no duplicate")
    }

    /// 영구 거절(413): 말풍선에 사람이 읽는 사유 · 화면 위 오류 없음 · 다음 동기화가 같은 바이트를 다시 올리거나 멈추지 않는다.
    func testPermanentRefusalFailsTheBubbleAndDoesNotBlockSync() async {
        let (model, relay) = await readyModel()
        relay.failNextPosts([.refused(code: "room_bytes_cap", status: 413)])
        let outcome = await model.send(room: "family", text: "too big")
        XCTAssertNil(outcome)
        guard case .failed(let reason)? = model.messages(room: "family").last?.outgoing else { return XCTFail() }
        XCTAssertTrue(reason.contains("413"), reason)
        XCTAssertNil(model.lastError, "the bubble carries the reason")

        await model.refresh()
        XCTAssertEqual(relay.applicationEvents(room: "family"), 0, "the closed entry is not posted again on the next poll")
        XCTAssertNil(model.lastError, "the sync round was not aborted")
        XCTAssertEqual(model.phase, .ready)
    }

    /// 보관됐던 글의 outbox 항목이 닫혔다(reconciled): 평문으로 한 번 새로 암호화해 보낸다 — 「연결되면 보냅니다」에 영원히 남지 않는다.
    func testQueuedMessageWhoseEntryIsReconciledIsResentOnce() async {
        let (model, relay) = await readyModel()
        await sendFirstSoTheRoomIsListed(model)
        relay.failNextPosts([.network("lost")])
        guard case .queued? = await model.send(room: "family", text: "later") else { return XCTFail() }
        relay.failNextPosts([.refused(code: "bad_request", status: 400)])

        await model.refresh()
        XCTAssertNil(model.outgoing["family"], "not stuck on 「연결되면 보냅니다」")
        XCTAssertEqual(relay.applicationEvents(room: "family"), 2, "hi + later, each once")
        XCTAssertEqual(model.messages(room: "family").map(\.record.body), ["hi", "later"])
    }

    /// 다시 보낸 것도 거절되면 「전송 안 됨」으로 끝난다(되풀이 없음).
    func testReconciledResendThatIsRefusedAgainEndsAsFailed() async {
        let (model, relay) = await readyModel()
        await sendFirstSoTheRoomIsListed(model)
        relay.failNextPosts([.network("lost")])
        guard case .queued? = await model.send(room: "family", text: "later") else { return XCTFail() }
        relay.failNextPosts([.refused(code: "bad_request", status: 400), .refused(code: "bad_request", status: 400)])

        await model.refresh()
        guard case .failed? = model.messages(room: "family").last?.outgoing else { return XCTFail("\(String(describing: model.outgoing))") }
        await model.refresh()
        guard case .failed? = model.messages(room: "family").last?.outgoing else { return XCTFail("stays failed, no loop") }
        XCTAssertEqual(relay.applicationEvents(room: "family"), 1, "only the first hi")
    }

    /// 메모리 릴레이는 이 기기의 이벤트가 있는 방만 목록에 올린다(실 릴레이는 참여한 방) — 먼저 한 글을 보내 동기화 바퀴가
    /// 그 방의 outbox 를 돌게 한다.
    private func sendFirstSoTheRoomIsListed(_ model: AppModel) async {
        guard case .sent? = await model.send(room: "family", text: "hi") else { return XCTFail("\(String(describing: model.lastError))") }
        await model.refresh()
    }

    /// #497: 보내는 글의 신호는 그 방에만 — 다른 방 화면은 다시 읽거나 스크롤하지 않는다(방 목록용 전역 신호는 그대로 오른다).
    func testSendBumpsOnlyThatRoomsRevision() async {
        let (model, _) = await readyModel()
        let family = model.roomRevision("family"), other = model.roomRevision("family-acc"), global = model.messagesRevision
        _ = await model.send(room: "family", text: "hi")
        XCTAssertGreaterThan(model.roomRevision("family"), family)
        XCTAssertEqual(model.roomRevision("family-acc"), other)
        XCTAssertGreaterThan(model.messagesRevision, global, "the room list still hears it")
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

    // MARK: - 단축어 「에이전트에게 보내기」(sendFromShortcut, 화면 위임 1단계)

    /// 참여한 에이전트 방(`jingun`)이 기록에 있는 준비된 모델. `login` 은 선택(준비 전 경로 시험).
    private func shortcutModel(login: Bool = true) async -> (AppModel, InMemoryRelay) {
        let relay = InMemoryRelay()
        let deps = AppModel.Dependencies(
            engineFactory: AnyFactory(MemberFakeFactory()), stateStore: InMemoryStateStore(),
            messageStore: InMemoryMessageStore(seedRooms: [RoomRecord(room: "jingun", epoch: 0, revision: 0, haltedReason: nil, displayOrder: 0)]),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "owner-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        let model = AppModel(dependencies: deps)
        if login { await model.bootstrap(); model.login(.bearer("t")); await model.refresh() }
        return (model, relay)
    }

    func testShortcutSendTrimsSendsAndAsksToOpenTheRoom() async {
        let (model, _) = await shortcutModel()
        XCTAssertEqual(model.phase, .ready)
        let result = await model.sendFromShortcut(room: "jingun", text: "  화면 내용\n클립보드  ")
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(model.messages(room: "jingun").map(\.record.body), ["화면 내용\n클립보드"], "same record as the composer path, trimmed")
        XCTAssertNil(model.outgoing["jingun"])
        XCTAssertEqual(model.requestedRoom, "jingun", "the reply arrives in that room — open it")
    }

    func testShortcutEmptyTextIsRefusedBeforeAnything() async {
        let (model, _) = await shortcutModel()
        let result = await model.sendFromShortcut(room: "jingun", text: " \n ")
        XCTAssertEqual(result, .failed(Strings.shortcutEmpty))
        XCTAssertNil(model.outgoing["jingun"], "nothing enqueued")
        XCTAssertNil(model.requestedRoom)
    }

    func testShortcutUnknownRoomIsRefused() async {
        let (model, _) = await shortcutModel()
        let result = await model.sendFromShortcut(room: "sogyo", text: "hi")
        XCTAssertEqual(result, .failed(Strings.shortcutUnknownRoom("sogyo")))
        XCTAssertNil(model.outgoing["sogyo"])
    }

    func testShortcutBeforeLoginReportsNotReady() async {
        let (model, _) = await shortcutModel(login: false)
        let result = await model.sendFromShortcut(room: "jingun", text: "hi")
        XCTAssertEqual(result, .failed(Strings.notReady))
        XCTAssertEqual(model.phase, .needsLogin, "bootstrapped by the shortcut, still waiting for login")
    }

    func testShortcutWhileRelayIsDownIsQueued() async throws {
        let (model, relay) = await shortcutModel()
        try await relay.stop()
        let result = await model.sendFromShortcut(room: "jingun", text: "later")
        XCTAssertEqual(result, .queued)
        XCTAssertEqual(model.messages(room: "jingun").first?.outgoing, .queued)
    }

    // MARK: - #643 공유 확장 맡김 → 앱이 보낸다(deliverPendingShares)

    private static let jpegHead = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00])
    /// 테스트 서버(`ServerSelection.testing`)의 스코프 — 앱이 지금 스코프의 맡김만 보낸다.
    private static var scope: String { ServerScope(baseURL: ServerSelection.testing.baseURL).id }

    private func shareContainer() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func shareFile(_ name: String, _ bytes: Data, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("picked-\(UUID().uuidString)-\(name)")
        try bytes.write(to: url)
        return url
    }

    /// `family`·`jingun` 이 기록에 있는 모델 + 맡김 저장소(+ 공유 대상 defaults). v1 첨부 경로(가짜 엔진, AttachmentTests 와 같다).
    private func shareModel(store: ShareHandoffStore, targets: ScopedDefaults? = nil, login: Bool = true) async -> AppModel {
        let relay = InMemoryRelay()
        var deps = AppModel.Dependencies(
            engineFactory: AnyFactory(MemberFakeFactory()), stateStore: InMemoryStateStore(),
            messageStore: InMemoryMessageStore(seedRooms: [
                RoomRecord(room: "family", epoch: 0, revision: 0, haltedReason: nil, displayOrder: 0),
                RoomRecord(room: "jingun", epoch: 0, revision: 0, haltedReason: nil, displayOrder: 1),
            ]),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "owner-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        deps.sendFileV2 = false
        deps.shareStore = store
        deps.shareTargets = targets
        let model = AppModel(dependencies: deps)
        await model.bootstrap()
        if login { model.login(.bearer("t")); await model.refresh() }
        return model
    }

    func testShareDeliverySendsTextThenFilesThroughTheSendPathAndOpensTheRoom() async throws {
        let container = try shareContainer()
        let store = ShareHandoffStore(container: container)
        let photo = Self.jpegHead + Data(repeating: 7, count: 200)
        try store.commit(scope: Self.scope, room: "family", text: "이거 봐 https://example.com/a",
                         files: [try shareFile("IMG.JPG", photo, in: container)])
        let model = await shareModel(store: store)
        XCTAssertEqual(model.phase, .ready)
        let delivered = await model.deliverPendingShares()
        XCTAssertEqual(delivered, 1)
        let mine = model.messages(room: "family")
        XCTAssertEqual(mine.map(\.record.kind), [.text, .attachment], "text first, then files in order")
        XCTAssertEqual(mine.first?.record.body, "이거 봐 https://example.com/a")
        XCTAssertEqual(mine.last?.record.body, "image/jpeg", "same sniffed row as the composer's attachment send")
        XCTAssertEqual(mine.last?.attachmentBytes, photo.count)
        XCTAssertEqual(model.requestedRoom, "family", "open the room it went to")
        XCTAssertNil(model.lastError)
        XCTAssertEqual(store.pending(scope: Self.scope), [], "delivered handoffs are gone")
        XCTAssertEqual(store.discardStaleClaims(), 0, "nothing left claimed")
    }

    func testShareDeliveryBeforeLoginKeepsTheHandoff() async throws {
        let store = ShareHandoffStore(container: try shareContainer())
        let item = try store.commit(scope: Self.scope, room: "family", text: "나중에", files: [])
        let model = await shareModel(store: store, login: false)
        let delivered = await model.deliverPendingShares()
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(store.pending(scope: Self.scope), [item], "kept for the next chance (foreground · notification tap)")
        XCTAssertNil(model.requestedRoom)
    }

    func testShareToARoomThisDeviceDoesNotHaveIsDroppedWithANotice() async throws {
        let store = ShareHandoffStore(container: try shareContainer())
        try store.commit(scope: Self.scope, room: "gone", text: "hi", files: [])
        let model = await shareModel(store: store)
        let delivered = await model.deliverPendingShares()
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(model.lastError, Strings.shareRoomGone("gone"))
        XCTAssertNil(model.outgoing["gone"], "nothing sent")
        XCTAssertEqual(store.pending(scope: Self.scope), [], "not retried forever")
    }

    func testOverlappingDeliveriesSendOnce() async throws {
        let store = ShareHandoffStore(container: try shareContainer())
        try store.commit(scope: Self.scope, room: "family", text: "한 번만", files: [])
        let model = await shareModel(store: store)
        async let first = model.deliverPendingShares()
        async let second = model.deliverPendingShares()
        let total = await first + second
        XCTAssertEqual(total, 1, "start · foreground · tap may overlap — one send")
        XCTAssertEqual(model.messages(room: "family").map(\.record.body), ["한 번만"])
    }

    func testShareFromAnotherServerScopeIsNotSent() async throws {
        let store = ShareHandoffStore(container: try shareContainer())
        let other = try store.commit(scope: "other-server", room: "family", text: "다른 서버", files: [])
        let model = await shareModel(store: store)
        let delivered = await model.deliverPendingShares()
        XCTAssertEqual(delivered, 0)
        XCTAssertTrue(model.messages(room: "family").isEmpty)
        XCTAssertEqual(store.pending(scope: "other-server"), [other], "kept until it expires")
    }

    func testShareTargetsArePublishedInListOrderForTheExtension() async throws {
        let suite = "share-targets-\(UUID().uuidString)"
        let base = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { base.removePersistentDomain(forName: suite) }
        let scoped = ScopedDefaults(base, scope: ServerScope(baseURL: ServerSelection.testing.baseURL))
        let model = await shareModel(store: ShareHandoffStore(container: try shareContainer()), targets: scoped)
        let expected = ShareHandoff.targets(model.listedRooms, saved: model.localPrefs.roomOrder)
        XCTAssertEqual(scoped.stringArray(forKey: ShareHandoff.targetsKey), expected)
        XCTAssertTrue(expected.contains("family"), "\(expected)")
        // 순서를 바꾸면 다음 바퀴(방 목록 다시 읽기)에 반영된다.
        model.localPrefs.setOrder(Array(expected.reversed()))
        await model.refresh()
        XCTAssertEqual(scoped.stringArray(forKey: ShareHandoff.targetsKey), Array(expected.reversed()))
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
