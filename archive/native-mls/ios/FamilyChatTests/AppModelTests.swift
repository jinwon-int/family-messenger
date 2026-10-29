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
        if let policy = FakePolicyWire.respond(method, input) { return policy }   // #574 policy_fingerprint · sign_approval · sign_roles
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
    func postLobbyKeyPackages(_ post: KeyPackagePost) async throws -> KeyPackagesResponse { try await inner.postLobbyKeyPackages(post) }
    func consumeLobbyKeyPackage(device: DeviceID, target: DeviceID, room: RoomID) async throws -> StoredKeyPackage? {
        try await inner.consumeLobbyKeyPackage(device: device, target: target, room: room)
    }
    func lobbyStatus(device: DeviceID) async throws -> LobbyStatus { try await inner.lobbyStatus(device: device) }
    func lobbyWelcomes(device: DeviceID) async throws -> [PendingWelcome] { try await inner.lobbyWelcomes(device: device) }
    func deleteLobbyKeyPackages(device: DeviceID) async throws -> Int { try await inner.deleteLobbyKeyPackages(device: device) }
    func postTyping(room: RoomID, device: DeviceID, clear: Bool) async throws { try await inner.postTyping(room: room, device: device, clear: clear) }
    func postRead(room: RoomID, device: DeviceID, seq: Int64) async throws -> Int64 { try await inner.postRead(room: room, device: device, seq: seq) }
    func postDeviceCandidate(_ post: DeviceCandidatePost) async throws -> DeviceCandidatePosted { try await inner.postDeviceCandidate(post) }
    func listDeviceCandidates(device: DeviceID) async throws -> DeviceCandidates { try await inner.listDeviceCandidates(device: device) }
    func postDeviceApproval(_ evidence: DeviceApprovalEvidence) async throws -> DevicePolicyCommit { try await inner.postDeviceApproval(evidence) }
    func postDeviceRoles(_ evidence: DeviceRolesEvidence) async throws -> DevicePolicyCommit { try await inner.postDeviceRoles(evidence) }
    func me() async throws -> MeResponse { try await inner.me() }
}

@MainActor
final class AppModelTests: XCTestCase {
    func makeModel(rooms: [RoomRecord] = [], format: UInt32 = 2, transport: RelayTransport? = InMemoryRelay(),
                   typingInterval: TimeInterval = 3)
        -> (AppModel, InMemoryStateStore) {
        let state = InMemoryStateStore()
        var deps = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: state, messageStore: InMemoryMessageStore(seedRooms: rooms),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "owner-iphone-abc123" }, expectedDecryptFormat: { format },
            makeTransport: { _ in transport })
        deps.typingInterval = typingInterval
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

    /// 오너 요청(build 29): 릴레이에 닿지 않으면 원문 오류 대신 「연결 중입니다…」, 다시 닿으면 사라진다.
    func testUnreachableRelayShowsConnectingNotRawError() async throws {
        let relay = InMemoryRelay()
        let (model, _) = makeModel(transport: relay)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.reconnecting)
        try await relay.stop()
        await model.refresh()
        XCTAssertTrue(model.reconnecting)
        XCTAssertNil(model.lastError, "no raw network error on screen")
        try await relay.start()
        await model.refresh()
        XCTAssertFalse(model.reconnecting, "one successful round clears it")
        XCTAssertNil(model.lastError)
    }

    // MARK: - 타이핑 (#562)

    /// 릴레이에 이 방의 로그가 있어야 GET /events 가 페이지(와 `typing`)를 준다 — 빈 방은 404 no_such_room. 다른 기기의 글 하나를
    /// 올려 두고(참여 전이라 읽지 않는다), 방 기록은 아는 방으로 시드한다(목록에 없어도 동기화한다).
    private func readyModel(relay: InMemoryRelay, typingInterval: TimeInterval = 3) async throws -> AppModel {
        let known = RoomRecord(room: "family", epoch: 0, revision: 0, haltedReason: nil, displayOrder: 0)
        let (model, _) = makeModel(rooms: [known], transport: relay, typingInterval: typingInterval)
        await model.bootstrap(); model.login(.bearer("t"))
        _ = try await relay.postEvent(room: "family", EventPost(device: "mom-iphone-1", clientId: "mom-iphone-1-c1", kind: .application,
                                                                epoch: 0, bytes: Data("hi".utf8)))
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        return model
    }

    func testTypingFromRelayIsSurfacedPerRoomAndCleared() async throws {
        let relay = InMemoryRelay()
        let model = try await readyModel(relay: relay)
        XCTAssertEqual(model.typing["family"], [], "a page without anyone typing yields an empty list, not nil")
        relay.setTyping(room: "family", devices: ["mom-iphone-1", model.deviceId])
        await model.refresh()
        XCTAssertEqual(model.typing["family"], ["mom-iphone-1"], "the relay never echoes the reader itself")
        relay.setTyping(room: "family", devices: [])
        await model.refresh()
        XCTAssertEqual(model.typing["family"], [])
    }

    func testTypingExpiresOnTheRelay() async throws {
        let relay = InMemoryRelay()
        let model = try await readyModel(relay: relay)
        let start = Date()
        relay.now = { start }
        relay.setTyping(room: "family", devices: ["mom-iphone-1"])
        await model.refresh()
        XCTAssertEqual(model.typing["family"], ["mom-iphone-1"])
        relay.now = { start.addingTimeInterval(7) }   // TTL 6s 지남
        await model.refresh()
        XCTAssertEqual(model.typing["family"], [])
    }

    func testNoteTypingIsThrottledPerRoomAndClearResetsTheWindow() async throws {
        let relay = InMemoryRelay()
        let model = try await readyModel(relay: relay)
        model.noteTyping(room: "family")
        model.noteTyping(room: "family")
        await model.typingInFlight?.value
        XCTAssertEqual(relay.typingPosts.count, 1, "interval 3s: the second change within the window does not post")
        XCTAssertEqual(relay.typingPosts.first?.room, "family")
        XCTAssertEqual(relay.typingPosts.first?.device, model.deviceId)
        XCTAssertEqual(relay.typingPosts.first?.clear, false)
        model.noteTyping(room: "family", clear: true)
        await model.typingInFlight?.value
        XCTAssertEqual(relay.typingPosts.count, 2)
        XCTAssertEqual(relay.typingPosts.last?.clear, true)
        model.noteTyping(room: "family", clear: true)
        await model.typingInFlight?.value
        XCTAssertEqual(relay.typingPosts.count, 2, "nothing to clear after a clear — no round trip")
        model.noteTyping(room: "family")
        await model.typingInFlight?.value
        XCTAssertEqual(relay.typingPosts.count, 3, "a clear resets the window")
    }

    func testNoteTypingWithZeroIntervalPostsEveryChange() async throws {
        let relay = InMemoryRelay()
        let model = try await readyModel(relay: relay, typingInterval: 0)
        model.noteTyping(room: "family")
        await model.typingInFlight?.value
        model.noteTyping(room: "family")
        await model.typingInFlight?.value
        XCTAssertEqual(relay.typingPosts.count, 2)
    }

    func testNoteTypingNeedsReadyPhaseAndReachableRelay() async throws {
        let relay = InMemoryRelay()
        let (model, _) = makeModel(transport: relay, typingInterval: 0)
        await model.bootstrap(); model.login(.bearer("t"))
        XCTAssertEqual(model.phase, .needsEnrollment)
        model.noteTyping(room: "family")
        await model.typingInFlight?.value
        XCTAssertTrue(relay.typingPosts.isEmpty, "not before the first successful round")
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        try await relay.stop()
        await model.refresh()
        XCTAssertTrue(model.reconnecting)
        model.noteTyping(room: "family")
        await model.typingInFlight?.value
        XCTAssertTrue(relay.typingPosts.isEmpty, "not while reconnecting")
        try await relay.start()
        await model.refresh()
        XCTAssertFalse(model.reconnecting)
        model.noteTyping(room: "family")
        await model.typingInFlight?.value
        XCTAssertEqual(relay.typingPosts.count, 1)
    }

    func testTypingIsDroppedWhenTheRelayBecomesUnreachable() async throws {
        let relay = InMemoryRelay()
        let model = try await readyModel(relay: relay)
        relay.setTyping(room: "family", devices: ["mom-iphone-1"])
        await model.refresh()
        XCTAssertEqual(model.typing["family"], ["mom-iphone-1"])
        try await relay.stop()
        await model.refresh()
        XCTAssertTrue(model.reconnecting)
        XCTAssertTrue(model.typing.isEmpty, "a stale 「입력중…」 must not survive a lost connection")
    }

    func testTypingRouteMissingOnOldRelayStopsFurtherPosts() async throws {
        let relay = InMemoryRelay()
        let model = try await readyModel(relay: relay, typingInterval: 0)
        relay.failNextTypingPosts([.refused(code: "http_404", status: 404)])
        model.noteTyping(room: "family")
        await model.typingInFlight?.value
        model.noteTyping(room: "family")
        await model.typingInFlight?.value
        model.noteTyping(room: "family", clear: true)
        await model.typingInFlight?.value
        XCTAssertEqual(relay.typingPosts.count, 1, "404 on the route = old relay; off for the session")
        // 다시 로그인하면(새 전송) 다시 묻는다.
        model.login(.bearer("t2"))
        await model.refresh()
        model.noteTyping(room: "family")
        await model.typingInFlight?.value
        XCTAssertEqual(relay.typingPosts.count, 2)
    }

    func testTypingNoSuchRoomIsNotTreatedAsMissingRoute() async throws {
        let relay = InMemoryRelay()
        let model = try await readyModel(relay: relay, typingInterval: 0)
        relay.failNextTypingPosts([.refused(code: "no_such_room", status: 404)])
        model.noteTyping(room: "family")
        await model.typingInFlight?.value
        model.noteTyping(room: "family")
        await model.typingInFlight?.value
        XCTAssertEqual(relay.typingPosts.count, 2, "a room that is not on the relay yet does not switch typing off")
    }

    // MARK: - 읽음 위치 공유 (#571 B)

    /// 다른 기기의 글 하나를 더 올린다(seq = 지금까지의 수 + 1) — 읽음 위치를 그만큼 올릴 수 있게.
    private func postMomMessage(_ relay: InMemoryRelay, _ n: Int) async throws {
        _ = try await relay.postEvent(room: "family", EventPost(device: "mom-iphone-1", clientId: "mom-iphone-1-c\(n)", kind: .application,
                                                                epoch: 0, bytes: Data("hi\(n)".utf8)))
    }

    /// 릴레이 `GET /events` 의 `read_seq`(같은 사람의 어느 기기든 본 위치)는 방별로 오르기만 한다; 다른 사람의 값은 내 것이 아니다.
    func testRelayReadSeqIsSurfacedPerRoomAndNeverShrinks() async throws {
        let relay = InMemoryRelay()
        let model = try await readyModel(relay: relay)
        XCTAssertEqual(model.relayReadSeq["family"] ?? 0, 0, "nothing read yet")
        relay.setRead(room: "family", device: "mom-iphone-1", seq: 1)   // 다른 사람(mom) — 이 기기(owner)의 값이 아니다
        await model.refresh()
        XCTAssertEqual(model.relayReadSeq["family"] ?? 0, 0, "another actor's read position is not mine")
        relay.setRead(room: "family", device: "owner-pc", seq: 1)   // 같은 사람(owner)의 다른 기기
        await model.refresh()
        XCTAssertEqual(model.relayReadSeq["family"], 1)
        model.logout()
        XCTAssertTrue(model.relayReadSeq.isEmpty, "logout drops the relay value (prefs keep the merged max)")
    }

    func testNoteReadPostsOncePerSeqAndTakesTheRelaysHigherAnswer() async throws {
        let relay = InMemoryRelay()
        let model = try await readyModel(relay: relay)
        model.noteRead(room: "family", seq: 0)
        await model.readInFlight?.value
        XCTAssertTrue(relay.readPosts.isEmpty, "seq 0 = nothing seen; no round trip")
        model.noteRead(room: "family", seq: 1)
        model.noteRead(room: "family", seq: 1)
        await model.readInFlight?.value
        XCTAssertEqual(relay.readPosts.count, 1, "the same seq is posted once")
        XCTAssertEqual(relay.readPosts.first?.room, "family")
        XCTAssertEqual(relay.readPosts.first?.device, model.deviceId)
        XCTAssertEqual(relay.readPosts.first?.seq, 1)
        XCTAssertEqual(model.relayReadSeq["family"], 1, "the 200 read_seq is applied")
        // 같은 사람의 다른 기기가 더 멀리 봤다: 응답 read_seq 가 올린 값보다 크다 → 그 값. 그 이하의 seq 는 다시 보내지 않는다.
        try await postMomMessage(relay, 2)
        try await postMomMessage(relay, 3)
        relay.setRead(room: "family", device: "owner-pc", seq: 3)
        model.noteRead(room: "family", seq: 2)
        await model.readInFlight?.value
        XCTAssertEqual(relay.readPosts.count, 2)
        XCTAssertEqual(relay.readPosts.last?.seq, 2)
        XCTAssertEqual(model.relayReadSeq["family"], 3, "another device of mine got further — the relay's answer wins")
        model.noteRead(room: "family", seq: 3)
        await model.readInFlight?.value
        XCTAssertEqual(relay.readPosts.count, 2, "the relay already knows 3 — no round trip")
    }

    func testNoteReadNeedsReadyPhaseAndReachableRelay() async throws {
        let relay = InMemoryRelay()
        let known = RoomRecord(room: "family", epoch: 0, revision: 0, haltedReason: nil, displayOrder: 0)
        let (model, _) = makeModel(rooms: [known], transport: relay)
        await model.bootstrap(); model.login(.bearer("t"))
        try await postMomMessage(relay, 1)
        XCTAssertEqual(model.phase, .needsEnrollment)
        model.noteRead(room: "family", seq: 1)
        await model.readInFlight?.value
        XCTAssertTrue(relay.readPosts.isEmpty, "not before the first successful round")
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        try await relay.stop()
        await model.refresh()
        XCTAssertTrue(model.reconnecting)
        model.noteRead(room: "family", seq: 1)
        await model.readInFlight?.value
        XCTAssertTrue(relay.readPosts.isEmpty, "not while reconnecting")
        try await relay.start()
        await model.refresh()
        XCTAssertFalse(model.reconnecting)
        model.noteRead(room: "family", seq: 1)
        await model.readInFlight?.value
        XCTAssertEqual(relay.readPosts.count, 1)
    }

    func testReadRouteMissingOnOldRelayStopsFurtherPosts() async throws {
        let relay = InMemoryRelay()
        let model = try await readyModel(relay: relay)
        relay.failNextReadPosts([.refused(code: "http_404", status: 404)])
        model.noteRead(room: "family", seq: 1)
        await model.readInFlight?.value
        try await postMomMessage(relay, 2)
        model.noteRead(room: "family", seq: 2)
        await model.readInFlight?.value
        XCTAssertEqual(relay.readPosts.count, 1, "404 on the route = old relay; off for the session")
        XCTAssertEqual(model.relayReadSeq["family"] ?? 0, 0, "a failed post applies nothing")
        // 다시 로그인하면(새 전송) 다시 묻는다.
        model.login(.bearer("t2"))
        await model.refresh()
        model.noteRead(room: "family", seq: 2)
        await model.readInFlight?.value
        XCTAssertEqual(relay.readPosts.count, 2)
        XCTAssertEqual(model.relayReadSeq["family"], 2)
    }

    func testReadNoSuchRoomIsNotTreatedAsMissingRoute() async throws {
        let relay = InMemoryRelay()
        let model = try await readyModel(relay: relay)
        relay.failNextReadPosts([.refused(code: "no_such_room", status: 404)])
        model.noteRead(room: "family", seq: 1)
        await model.readInFlight?.value
        try await postMomMessage(relay, 2)
        model.noteRead(room: "family", seq: 2)
        await model.readInFlight?.value
        XCTAssertEqual(relay.readPosts.count, 2, "a room that is not on the relay yet does not switch read sharing off")
    }

    func testConnectionIssueClassification() async {
        let cancelled = RelayError.network(#"Error Domain=NSURLErrorDomain Code=-999 "취소됨" UserInfo={…}"#)
        XCTAssertEqual(ConnectionIssue.classify(cancelled, taskCancelled: false), .cancelled, "build 29 screenshot")
        XCTAssertEqual(ConnectionIssue.classify(CancellationError(), taskCancelled: false), .cancelled)
        XCTAssertEqual(ConnectionIssue.classify(URLError(.cancelled), taskCancelled: false), .cancelled)
        XCTAssertEqual(ConnectionIssue.classify(RelayError.network("relay down"), taskCancelled: true), .cancelled, "the screen task was cancelled")
        XCTAssertEqual(ConnectionIssue.classify(URLError(.notConnectedToInternet), taskCancelled: false), .unreachable)
        XCTAssertEqual(ConnectionIssue.classify(RelayError.network("Error Domain=NSURLErrorDomain Code=-1005"), taskCancelled: false), .unreachable)
        XCTAssertEqual(ConnectionIssue.classify(RelayError.refused(code: "bad_gateway", status: 502), taskCancelled: false), .unreachable)
        XCTAssertEqual(ConnectionIssue.classify(RelayError.network("bad relay url: x /v2"), taskCancelled: false), .other)
        XCTAssertEqual(ConnectionIssue.classify(RelayError.refused(code: "not_a_member", status: 403), taskCancelled: false), .other)
        XCTAssertEqual(ConnectionIssue.classify(RelayError.decoding("x"), taskCancelled: false), .other)
    }

    func testRefreshWithNoRoomsIsReady() async {
        let (model, _) = makeModel()
        await model.bootstrap(); model.login(.bearer("t"))
        XCTAssertFalse(model.settled, "#414: before the first refresh the screen shows the opening, not enrollment")
        await model.refresh()
        XCTAssertTrue(model.settled)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.lastError)
    }

    func testUnregisteredDeviceWaitsForOperator() async {
        let (model, _) = makeModel(transport: RefusingRelay(RelayError.refused(code: "device_subject_mismatch", status: 403)))
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.phase, .needsEnrollment)
        XCTAssertTrue(model.settled, "#414: a real 'not enrolled' answer is shown, not hidden behind the opening")
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

    /// `header.payload.sig` 꼴의 가짜 CF Access JWT(서명 없음 — 앱은 검증하지 않고 `sub` 만 읽는다).
    static func accessJWT(sub: String) -> String {
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return b64url("{\"alg\":\"RS256\"}") + "." + b64url("{\"sub\":\"\(sub)\",\"email\":\"o@example.com\"}") + ".c2ln"
    }

    func testLoginFillsEnrollmentSubjectFromAccessJWT() async {
        let (model, _) = makeModel()
        await model.bootstrap()
        XCTAssertEqual(model.registration?.subject, "", "before login the app does not know the subject")
        model.login(.accessCookie(Self.accessJWT(sub: "cf-sub-7c1f")))
        XCTAssertEqual(model.registration?.subject, "cf-sub-7c1f")
        XCTAssertTrue(model.registrationJSON().contains("\"subject\" : \"cf-sub-7c1f\""), model.registrationJSON())
        XCTAssertEqual(model.fingerprint, model.registration?.fingerprint, "only the subject changes; the key material does not")
        model.login(.bearer(Self.accessJWT(sub: "")))
        XCTAssertEqual(model.registration?.subject, "", "a service token (empty sub) leaves the subject for the operator")
    }

    func testRequestJoinPublishesKeyPackageAndListsRoom() async throws {
        let relay = InMemoryRelay()
        let (model, _) = makeModel(transport: relay)
        await model.bootstrap(); model.login(.bearer("t"))
        XCTAssertFalse(model.canRequestJoin, "no join request while enrollment is still unconfirmed")
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.canRequestJoin)
        try await model.requestJoin(room: "family")
        XCTAssertEqual(model.rooms.map(\.room), ["family"], "the requested room shows up at once")
        let listing = try await relay.listRooms(device: model.deviceId)
        XCTAssertEqual(listing.rooms.map(\.room), ["family"])
        XCTAssertEqual(listing.rooms.first?.keypackagesOutstanding, 1, "exactly one key package was published")
        XCTAssertEqual(listing.rooms.first?.member, false, "publishing is not joining — the inviter's commit does that")
    }

    func testLogoutKeepsIdentity() async {
        let (model, _) = makeModel()
        await model.bootstrap(); model.login(.bearer("t"))
        let fp = model.fingerprint
        model.logout()
        XCTAssertEqual(model.phase, .needsLogin)
        XCTAssertEqual(model.fingerprint, fp)
    }

    // MARK: 서버 선택·전환 (#584 PR 2)

    private static let found = ServerInfo(baseURL: URL(string: "https://relay.example.com")!, name: "집", discoveredVia: .wellKnown)

    private func serverModel(server: ServerSelection?, store: InMemoryServerStore = InMemoryServerStore(), actor: String? = "owner",
                             discover: @escaping (String) async -> Result<ServerInfo, ServerDiscoveryFailure> = { _ in .success(AppModelTests.found) })
        -> (AppModel, InMemoryCredentialStore, InMemoryServerStore) {
        let credentials = InMemoryCredentialStore()
        var deps = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: InMemoryStateStore(), messageStore: InMemoryMessageStore(),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "owner-iphone-abc123" }, expectedDecryptFormat: { 2 },
            makeTransport: { _ in InMemoryRelay() })
        deps.credentials = credentials
        deps.actorStore = InMemoryActorStore(actor)
        deps.server = server
        deps.serverStore = store
        deps.discoverServer = discover
        return (AppModel(dependencies: deps), credentials, store)
    }

    func testBootstrapNeedsServerWhenNothingIsSelectedAndNoDefault() async {
        let (model, _, _) = serverModel(server: nil, actor: nil)
        await model.bootstrap()
        XCTAssertEqual(model.phase, .needsServer, "App Store build, first run: pick a server before anything else")
        XCTAssertEqual(model.deviceId, "", "no identity is created without a server scope")
        XCTAssertNil(model.server)
        // 서버 전에는 이름도 로그인도 받지 않는다
        let chosen = await model.chooseActor("mom")
        XCTAssertFalse(chosen)
        XCTAssertEqual(model.phase, .needsServer)
    }

    func testBuildDefaultOrSavedSelectionSkipsTheServerScreen() async {
        let (fromDefault, _, _) = serverModel(server: ServerSelection(defaultURL: URL(string: "https://family.example.com")!))
        await fromDefault.bootstrap()
        XCTAssertEqual(fromDefault.phase, .needsLogin, "family TestFlight: FC_RELAY_URL default is adopted silently")
        XCTAssertEqual(fromDefault.server?.discoveredVia, .buildDefault)

        let saved = ServerSelection(info: Self.found, at: Date(timeIntervalSince1970: 5))
        let (fromStore, _, _) = serverModel(server: saved, store: InMemoryServerStore(.selected(saved)), actor: nil)
        await fromStore.bootstrap()
        XCTAssertEqual(fromStore.phase, .needsActor, "selected server, fresh scope → actor name next")
    }

    private final class Calls { var raw: [String] = [] }

    func testDiscoverThenSelectServerContinuesTheExistingFlow() async {
        let asked = Calls()
        let (model, _, store) = serverModel(server: nil, actor: nil, discover: { raw in asked.raw.append(raw); return .success(AppModelTests.found) })
        await model.bootstrap()
        await model.discoverServer("hande://server?url=example.com")
        XCTAssertEqual(asked.raw, ["example.com"], "a pasted hande://server link is unwrapped before discovery")
        XCTAssertEqual(model.serverCandidate, Self.found)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.discovering)

        await model.selectServer(Self.found)
        XCTAssertEqual(model.phase, .needsActor, "new scope is empty → actor name → login → enrollment")
        XCTAssertEqual(model.server?.baseURL, Self.found.baseURL)
        XCTAssertEqual(model.server?.name, "집")
        XCTAssertEqual(model.relayURL, Self.found.baseURL, "login sheet opens the chosen relay")
        if case .selected(let selection) = store.load() { XCTAssertEqual(selection.baseURL, Self.found.baseURL) } else { XCTFail("selection persisted") }
        XCTAssertNil(model.serverCandidate)
        let chosen = await model.chooseActor("mom")
        XCTAssertTrue(chosen)
        XCTAssertEqual(model.phase, .needsLogin)
    }

    func testDiscoverFailureIsShownAndNothingIsSelected() async {
        let (model, _, store) = serverModel(server: nil, actor: nil, discover: { _ in .failure(.notFound(host: "nowhere.example")) })
        await model.bootstrap()
        await model.discoverServer("nowhere.example")
        XCTAssertNil(model.serverCandidate)
        XCTAssertEqual(model.lastError, Strings.serverDiscoveryFailure(.notFound(host: "nowhere.example")))
        XCTAssertEqual(model.phase, .needsServer)
        XCTAssertEqual(store.load(), .unset)
        // 선택 화면이 아니면 탐색하지 않는다
        let (ready, _, _) = serverModel(server: .testing)
        await ready.bootstrap()
        await ready.discoverServer("example.com")
        XCTAssertNil(ready.serverCandidate)
    }

    func testChangeServerLogsOutClearsTheSelectionAndStartsTheNextScopeEmpty() async {
        let (model, credentials, store) = serverModel(server: .testing, store: InMemoryServerStore(.selected(.testing)))
        await model.bootstrap(); model.login(.bearer("jwt")); await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNotNil(credentials.load())
        let oldDevice = model.deviceId

        await model.changeServer()
        XCTAssertEqual(model.phase, .needsServer)
        XCTAssertNil(credentials.load(), "logged out: this scope's credential is deleted")
        XCTAssertEqual(store.load(), .cleared, "next launch must not fall back to the build default")
        XCTAssertNil(model.server); XCTAssertNil(model.relayURL)
        XCTAssertEqual(model.deviceId, ""); XCTAssertEqual(model.fingerprint, "")
        XCTAssertTrue(model.rooms.isEmpty)
        XCTAssertEqual(model.pushStatus, .off)
        XCTAssertFalse(oldDevice.isEmpty)

        // 다시 고르면 그 서버로 시작을 이어 간다(테스트 의존성은 그 자리에서 바뀐다 — live 는 reopen 으로 새 스코프 저장소를 연다)
        await model.selectServer(Self.found)
        XCTAssertEqual(model.phase, .needsLogin)
        XCTAssertEqual(model.server?.baseURL, Self.found.baseURL)
    }

    func testReopenHookRebuildsDependenciesForTheNewScope() async {
        // reopen = live() 의 자리: 새 스코프의 저장소·identity·actor 를 다시 조립한다
        let reopened = Calls()
        var template = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: InMemoryStateStore(), messageStore: InMemoryMessageStore(),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-000001" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in InMemoryRelay() })
        template.server = nil
        template.actorStore = InMemoryActorStore(nil)
        let base = template
        var deps = template
        deps.reopen = { selection in
            reopened.raw.append(selection?.baseURL.absoluteString ?? "nil")
            var next = base
            next.server = selection
            next.actorStore = InMemoryActorStore("mom")
            next.relayURL = selection?.baseURL
            return next
        }
        let reopening = AppModel(dependencies: deps)
        await reopening.bootstrap()
        XCTAssertEqual(reopening.phase, .needsServer)
        await reopening.selectServer(Self.found)
        XCTAssertEqual(reopened.raw, [Self.found.baseURL.absoluteString])
        XCTAssertEqual(reopening.phase, .needsLogin, "the reopened scope already has an actor")
        XCTAssertEqual(reopening.deviceId, "mom-iphone-000001")
        XCTAssertEqual(reopening.relayURL, Self.found.baseURL)
    }
}
