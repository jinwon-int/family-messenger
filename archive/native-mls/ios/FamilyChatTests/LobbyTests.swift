// 로비 key package(#380 P5-3) — AppModel 쪽: 로그인 뒤 첫 바퀴의 보충 · 전면 복귀에만 status 를 다시 묻는다 · 로비 없는 릴레이(404)
// 는 조용히 건너뛴다 · Welcome 발견은 actor 에 따라 (A) 자동 받아들이기 / (B) 수락 대기(무시·수락) 로 갈린다.
// 가짜 엔진(FakeFactory: 모든 연산 성공, 그룹 roster 는 없음)이라 "참여" 자체는 여기서 끝나지 않는다 — 실 엔진의 탭 없는 참여는
// TwoDeviceScenario ⑥(IntegrationTests · RelaySmokeTests · Linux 스모크)이 검증한다.
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class LobbyTests: XCTestCase {
    private func makeModel(actor: String, relay: RelayTransport, lobbyTarget: Int = 8) -> (AppModel, InMemoryStateStore, InMemoryCursorStore) {
        let state = InMemoryStateStore()
        let cursors = InMemoryCursorStore()
        var deps = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: state, messageStore: InMemoryMessageStore(),
            outbox: InMemoryOutboxStore(), cursors: cursors,
            identityProvider: { "\(actor)-iphone-abc123" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        deps.actorStore = InMemoryActorStore(actor)
        deps.lobbyTarget = lobbyTarget
        return (AppModel(dependencies: deps), state, cursors)
    }

    private func slot(_ state: InMemoryStateStore) throws -> LobbySlot? {
        try state.withExclusive(room: LobbyKeyring.slot, timeout: 1) { tx in
            try tx.load().map { try JSONDecoder().decode(LobbySlot.self, from: $0) }
        }
    }

    func testFirstRoundAfterLoginFillsTheLobbyAndLaterRoundsDoNotAskAgain() async throws {
        let relay = CountingRelay()
        let (model, state, _) = makeModel(actor: "owner", relay: relay)
        await model.bootstrap(); model.login(.bearer("t"))
        XCTAssertNil(model.lobbyLive)
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.lobbyLive, 8)
        XCTAssertEqual(relay.inner.lobbyLiveCount(model.deviceId), 8)
        XCTAssertEqual(try slot(state)?.published.count, 8, "ledger persisted in the _lobby slot")
        XCTAssertEqual(relay.statusCalls, 1)
        XCTAssertFalse(model.rooms.contains { $0.room == LobbyKeyring.slot }, "the slot is not a room")

        await model.refresh(); await model.refresh()
        XCTAssertEqual(relay.statusCalls, 1, "4-second polling does not hit /lobby/status")
        XCTAssertEqual(relay.welcomeCalls, 3, "but every round looks for pending Welcomes")

        await model.foregrounded()
        XCTAssertEqual(relay.statusCalls, 2, "foreground return re-checks the lobby")
        XCTAssertEqual(model.lobbyLive, 8)
    }

    func testLobbyIsOptional() async throws {
        let (off, offState, _) = makeModel(actor: "owner", relay: InMemoryRelay(), lobbyTarget: 0)
        await off.bootstrap(); off.login(.bearer("t")); await off.refresh()
        XCTAssertEqual(off.phase, .ready)
        XCTAssertNil(off.lobbyLive)
        XCTAssertNil(try slot(offState), "lobbyTarget 0 never creates a slot")

        let legacy = RefusingLobbyRelay()
        let (old, oldState, _) = makeModel(actor: "owner", relay: legacy)
        await old.bootstrap(); old.login(.bearer("t")); await old.refresh()
        XCTAssertEqual(old.phase, .ready, "a relay without lobby routes is not an error (\(old.lastError ?? "-"))")
        XCTAssertNil(old.lastError)
        XCTAssertNil(old.lobbyLive)
        XCTAssertNil(try slot(oldState))
        await old.foregrounded()
        XCTAssertEqual(legacy.lobbyCalls, 1, "after one 404 the session stops asking")
    }

    func testUnregisteredDeviceWaitsBeforePublishing() async throws {
        let relay = CountingRelay()
        relay.deviceNotAllowed = true
        let (model, state, _) = makeModel(actor: "owner", relay: relay)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.lastError, "403 device_not_allowed is 'not yet', not an error")
        XCTAssertNil(try slot(state), "no local secrets are minted before the relay accepts the device")
        relay.deviceNotAllowed = false
        await model.refresh()
        XCTAssertEqual(model.lobbyLive, 8, "the next round after enrollment publishes")
    }

    /// 가족 actor(B): Welcome 이 있는 모르는 방은 자동으로 들어가지 않고 수락 대기 목록에 오른다. 무시 = 이 세션에서 숨김.
    func testFamilyDeviceWaitsForOneTapAccept() async throws {
        let relay = CountingRelay()
        let (model, state, _) = makeModel(actor: "mom", relay: relay)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertFalse(model.autoJoinsLobbyInvites)
        relay.inner.seedWelcome(room: "ops-yukson", target: model.deviceId)
        await model.refresh()
        XCTAssertEqual(model.pendingInvites.map(\.room), ["ops-yukson"])
        XCTAssertNil(model.notice)
        // 방 목록(/v2/rooms)은 봇의 commit 이 이 기기를 넣었으므로 방을 보이지만, 상태는 로비로 바뀌지 않았다(identity 시드 그대로).
        let untouched = try state.withExclusive(room: "ops-yukson", timeout: 1) { try $0.load() }
        XCTAssertNotEqual(untouched, try slot(state)?.state, "B: the room state is not adopted before the tap")
        // #389: 기록은 있지만(목록이 방을 돌려준다) 대화 목록에는 「새 대화방 초대」 칸에만 보인다.
        XCTAssertTrue(model.rooms.contains { $0.room == "ops-yukson" }, "the relay listing already created the record")
        XCTAssertFalse(model.listedRooms.contains { $0.room == "ops-yukson" }, "#389: hidden from the room list until accepted")

        model.dismissInvite(room: "ops-yukson")
        XCTAssertTrue(model.pendingInvites.isEmpty)
        await model.refresh()
        XCTAssertTrue(model.pendingInvites.isEmpty, "dismissed for this session even though the Welcome is still listed")

        // 수락: 방 상태가 로비 슬롯으로 바뀌고(adopt) 커서가 Welcome 앞에 서며 방이 목록에 오른다. 가짜 엔진은 roster 가 없어 join 은
        // 확인되지 않는다(실 엔진 = TwoDeviceScenario ⑥) → notJoined 로 알린다.
        let (fresh, _, freshCursors) = makeModel(actor: "mom", relay: relay)
        await fresh.bootstrap(); fresh.login(.bearer("t")); await fresh.refresh()
        XCTAssertEqual(fresh.pendingInvites.map(\.room), ["ops-yukson"])
        do {
            try await fresh.acceptInvite(room: "ops-yukson")
            XCTFail("fake engine cannot prove the join")
        } catch SyncError.notJoined {
            // expected with FakeFactory
        }
        XCTAssertTrue(fresh.pendingInvites.isEmpty)
        XCTAssertTrue(fresh.rooms.contains { $0.room == "ops-yukson" }, "the adopted room is listed")
        XCTAssertTrue(fresh.listedRooms.contains { $0.room == "ops-yukson" }, "#389: listed once accepted")
        XCTAssertEqual(try freshCursors.cursor(room: "ops-yukson"), relay.inner.welcomeSeq(room: "ops-yukson"), "cursor advanced past the Welcome by the sync")
    }

    /// #389: 「이 기기 지우기」는 옛 신원의 로비 키를 먼저 거둔다. 로비가 없는 릴레이(404)·꺼진 릴레이여도 리셋은 끝난다.
    func testWipeDeviceWithdrawsTheLobbyKeysFirst() async throws {
        let relay = CountingRelay()
        let (model, _, _) = makeModel(actor: "owner", relay: relay)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        let device = model.deviceId
        XCTAssertEqual(relay.inner.lobbyLiveCount(device), 8)
        try await model.wipeDevice()
        XCTAssertEqual(relay.inner.lobbyLiveCount(device), 0, "the old identity's lobby keys are gone")
        XCTAssertEqual(model.phase, .needsLogin, "the reset finished")

        let refusing = RefusingLobbyRelay()
        let (other, _, _) = makeModel(actor: "owner", relay: refusing)
        await other.bootstrap(); other.login(.bearer("t")); await other.refresh()
        try await other.wipeDevice()
        XCTAssertEqual(other.phase, .needsLogin, "a relay without the lobby (404) does not block the reset")

        let down = CountingRelay()
        let (third, _, _) = makeModel(actor: "owner", relay: down)
        await third.bootstrap(); third.login(.bearer("t")); await third.refresh()
        try await down.inner.stop()
        try await third.wipeDevice()
        XCTAssertEqual(third.phase, .needsLogin, "an unreachable relay does not block the reset")
        XCTAssertEqual(down.inner.lobbyLiveCount("owner-iphone-abc123"), 8, "nothing was withdrawn — TTL cleans up")
    }

    /// 오너 actor(A): 같은 Welcome 을 묻지 않고 받아들인다(방 상태 교체 + 방 목록). 실패한 seq 는 다시 시도하지 않는다.
    func testOwnerDeviceAdoptsAutomaticallyAndDoesNotRetryTheSameWelcome() async throws {
        let relay = CountingRelay()
        let (model, state, _) = makeModel(actor: "owner", relay: relay)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertTrue(model.autoJoinsLobbyInvites)
        relay.inner.seedWelcome(room: "ops-yukson", target: model.deviceId)
        await model.refresh()
        XCTAssertTrue(model.pendingInvites.isEmpty, "A: no question")
        XCTAssertTrue(model.rooms.contains { $0.room == "ops-yukson" })
        let adopted = try XCTUnwrap(try state.withExclusive(room: "ops-yukson", timeout: 1) { try $0.load() })
        let slotState = try XCTUnwrap(try slot(state)?.state)
        XCTAssertTrue(adopted.starts(with: slotState), "the room state started as a copy of the _lobby slot (then the join attempt appended)")
        XCTAssertGreaterThan(slotState.count, 3, "the slot holds the minted key packages, the identity seed alone does not")
        // 가짜 엔진은 참여를 증명하지 못하므로(join 은 '성공'하지만 roster 없음) 같은 seq 는 adoptFailed 로 남아 상태를 다시 바꾸지 않는다.
        let generation = try state.generation(room: "ops-yukson")
        let reads = relay.inner.eventReads(room: "ops-yukson")
        await model.refresh()
        XCTAssertEqual(relay.inner.eventReads(room: "ops-yukson"), reads + 1, "the room is synced like any other room …")
        XCTAssertEqual(try state.generation(room: "ops-yukson"), generation, "… but not adopted again for the same Welcome")
        XCTAssertTrue(model.pendingInvites.isEmpty)
    }
}

// MARK: - 대역

/// InMemoryRelay 에 로비 호출 횟수·403 스위치를 얹는다.
final class CountingRelay: InMemoryRelayWrapper {
    var statusCalls = 0
    var welcomeCalls = 0
    var deviceNotAllowed = false

    override func postLobbyKeyPackages(_ post: KeyPackagePost) async throws -> KeyPackagesResponse {
        if deviceNotAllowed { throw RelayError.refused(code: "device_not_allowed", status: 403) }
        return try await inner.postLobbyKeyPackages(post)
    }
    override func lobbyStatus(device: DeviceID) async throws -> LobbyStatus {
        statusCalls += 1
        if deviceNotAllowed { throw RelayError.refused(code: "device_not_allowed", status: 403) }
        return try await inner.lobbyStatus(device: device)
    }
    override func lobbyWelcomes(device: DeviceID) async throws -> [PendingWelcome] {
        welcomeCalls += 1
        if deviceNotAllowed { throw RelayError.refused(code: "device_not_allowed", status: 403) }
        return try await inner.lobbyWelcomes(device: device)
    }
}

/// 로비 라우트가 없는 옛 릴레이: 로비 호출마다 404.
final class RefusingLobbyRelay: InMemoryRelayWrapper {
    var lobbyCalls = 0
    override func postLobbyKeyPackages(_ post: KeyPackagePost) async throws -> KeyPackagesResponse { lobbyCalls += 1; throw RelayError.refused(code: "not_found", status: 404) }
    override func lobbyStatus(device: DeviceID) async throws -> LobbyStatus { lobbyCalls += 1; throw RelayError.refused(code: "not_found", status: 404) }
    override func lobbyWelcomes(device: DeviceID) async throws -> [PendingWelcome] { lobbyCalls += 1; throw RelayError.refused(code: "not_found", status: 404) }
    override func deleteLobbyKeyPackages(device: DeviceID) async throws -> Int { lobbyCalls += 1; throw RelayError.refused(code: "not_found", status: 404) }
}
