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
    func postLobbyKeyPackages(_ post: KeyPackagePost) async throws -> KeyPackagesResponse { try await inner.postLobbyKeyPackages(post) }
    func consumeLobbyKeyPackage(device: DeviceID, target: DeviceID, room: RoomID) async throws -> StoredKeyPackage? {
        try await inner.consumeLobbyKeyPackage(device: device, target: target, room: room)
    }
    func lobbyStatus(device: DeviceID) async throws -> LobbyStatus { try await inner.lobbyStatus(device: device) }
    func lobbyWelcomes(device: DeviceID) async throws -> [PendingWelcome] { try await inner.lobbyWelcomes(device: device) }
    func deleteLobbyKeyPackages(device: DeviceID) async throws -> Int { try await inner.deleteLobbyKeyPackages(device: device) }
    func postTyping(room: RoomID, device: DeviceID, clear: Bool) async throws { try await inner.postTyping(room: room, device: device, clear: clear) }
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
}
