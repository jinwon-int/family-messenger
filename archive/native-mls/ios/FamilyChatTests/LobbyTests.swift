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
        // #389: 기록은 있지만(목록이 방을 돌려준다) 대화 목록에는 없고 🔔 알림 시트의 「새 대화방 초대」 칸에만 보인다.
        XCTAssertTrue(model.rooms.contains { $0.room == "ops-yukson" }, "the relay listing already created the record")
        XCTAssertFalse(model.listedRooms.contains { $0.room == "ops-yukson" }, "#389: hidden from the room list until accepted")

        model.dismissInvite(room: "ops-yukson")
        XCTAssertTrue(model.pendingInvites.isEmpty)
        await model.refresh()
        XCTAssertTrue(model.pendingInvites.isEmpty, "dismissed for this session even though the Welcome is still listed")

        // 수락: 방 상태가 로비 슬롯으로 바뀌고(adopt) 커서가 Welcome 앞에 선다. 가짜 엔진은 roster 가 없어 join 은 확인되지 않는다
        // (실 엔진 = TwoDeviceScenario ⑥) → notJoined 로 알리고, 초대는 실패 상태와 함께 남아 「다시 시도」할 수 있다(#521).
        let (fresh, _, freshCursors) = makeModel(actor: "mom", relay: relay)
        await fresh.bootstrap(); fresh.login(.bearer("t")); await fresh.refresh()
        XCTAssertEqual(fresh.pendingInvites.map(\.room), ["ops-yukson"])
        XCTAssertEqual(fresh.inviteStates["ops-yukson"], AppModel.InviteState.new)
        do {
            try await fresh.acceptInvite(room: "ops-yukson")
            XCTFail("fake engine cannot prove the join")
        } catch SyncError.notJoined {
            // expected with FakeFactory
        }
        XCTAssertEqual(fresh.pendingInvites.map(\.room), ["ops-yukson"], "#521: a failed accept keeps the invite (with its state)")
        XCTAssertEqual(fresh.inviteStates["ops-yukson"], AppModel.InviteState.failed(tries: 1, reason: Strings.notJoined))
        XCTAssertTrue(fresh.rooms.contains { $0.room == "ops-yukson" }, "the adopted room has a record")
        XCTAssertFalse(fresh.listedRooms.contains { $0.room == "ops-yukson" }, "#389: still only in the invite section until joined")
        XCTAssertEqual(try freshCursors.cursor(room: "ops-yukson"), relay.inner.welcomeSeq(room: "ops-yukson"), "cursor advanced past the Welcome by the sync")
        await fresh.refresh()
        XCTAssertEqual(fresh.inviteStates["ops-yukson"], AppModel.InviteState.failed(tries: 1, reason: Strings.notJoined),
                       "B: no automatic retry — the next round keeps the invite and its state")
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

    /// 오너 actor(A): 같은 Welcome 을 묻지 않고 받아들인다(방 상태 교체 + 방 목록). 실패한 seq 는 세션당 `adoptTries`(2) 번까지만
    /// 자동으로 다시 시도하고, 그 뒤에는 🔔·초대 카드에 상태와 함께 남는다(#521). 「다시 시도」는 횟수를 되돌리고, 「무시」는 이 세션에서 숨긴다.
    func testOwnerDeviceAdoptsAutomaticallyAndRetriesOnceBeforeLeavingTheInviteInTheBell() async throws {
        let relay = CountingRelay()
        let (model, state, _) = makeModel(actor: "owner", relay: relay)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertTrue(model.autoJoinsLobbyInvites)
        relay.inner.seedWelcome(room: "ops-yukson", target: model.deviceId)
        await model.refresh()
        XCTAssertTrue(model.rooms.contains { $0.room == "ops-yukson" })
        let adopted = try XCTUnwrap(try state.withExclusive(room: "ops-yukson", timeout: 1) { try $0.load() })
        let slotState = try XCTUnwrap(try slot(state)?.state)
        XCTAssertTrue(adopted.starts(with: slotState), "the room state started as a copy of the _lobby slot (then the join attempt appended)")
        XCTAssertGreaterThan(slotState.count, 3, "the slot holds the minted key packages, the identity seed alone does not")
        // 가짜 엔진은 참여를 증명하지 못하므로(join 은 '성공'하지만 roster 없음) 실패로 기록되고 — 조용히 사라지지 않는다(#521).
        XCTAssertEqual(model.pendingInvites.map(\.room), ["ops-yukson"], "A: the failed auto-join stays visible")
        XCTAssertEqual(model.inviteStates["ops-yukson"], AppModel.InviteState.failed(tries: 1, reason: Strings.notJoined))
        XCTAssertFalse(model.listedRooms.contains { $0.room == "ops-yukson" }, "#389: hidden from the room list until joined")

        // 두 번째 바퀴 = 세션당 한 번뿐인 자동 재시도(상태를 다시 바꾼다). 세 번째부터는 건드리지 않는다.
        var generation = try state.generation(room: "ops-yukson")
        await model.refresh()
        XCTAssertNotEqual(try state.generation(room: "ops-yukson"), generation, "retried once: adopted again for the same Welcome")
        XCTAssertEqual(model.inviteStates["ops-yukson"], AppModel.InviteState.failed(tries: AppModel.adoptTries, reason: Strings.notJoined))
        generation = try state.generation(room: "ops-yukson")
        let reads = relay.inner.eventReads(room: "ops-yukson")
        await model.refresh()
        XCTAssertEqual(relay.inner.eventReads(room: "ops-yukson"), reads + 1, "the room is synced like any other room …")
        XCTAssertEqual(try state.generation(room: "ops-yukson"), generation, "… but not adopted again once the tries are exhausted")
        XCTAssertEqual(model.pendingInvites.map(\.room), ["ops-yukson"])
        XCTAssertEqual(model.inviteStates["ops-yukson"], AppModel.InviteState.failed(tries: AppModel.adoptTries, reason: Strings.notJoined))

        // 「다시 시도」(🔔·카드): 횟수를 되돌리고 한 번 더 받아들인다 — 가짜 엔진이라 다시 notJoined, 상태는 1회부터.
        do {
            try await model.acceptInvite(room: "ops-yukson")
            XCTFail("fake engine cannot prove the join")
        } catch SyncError.notJoined {
            // expected with FakeFactory
        }
        XCTAssertNotEqual(try state.generation(room: "ops-yukson"), generation, "a manual retry adopts again")
        XCTAssertEqual(model.inviteStates["ops-yukson"], AppModel.InviteState.failed(tries: 1, reason: Strings.notJoined))

        // 「무시」: 이 세션에서는 자동 시도도 하지 않는다(상태 불변).
        model.dismissInvite(room: "ops-yukson")
        XCTAssertTrue(model.pendingInvites.isEmpty)
        XCTAssertNil(model.inviteStates["ops-yukson"])
        generation = try state.generation(room: "ops-yukson")
        await model.refresh()
        XCTAssertTrue(model.pendingInvites.isEmpty, "dismissed for this session")
        XCTAssertEqual(try state.generation(room: "ops-yukson"), generation, "no automatic attempt on a dismissed invite")
    }

    /// #530(웹 #531 과 동일): 제거→재초대 뒤 한 방에 옛 Welcome(seq 2)과 새 Welcome(seq 4)이 함께 오면 **seq 최대인 것만** 시도한다 —
    /// 옛 것의 로비 키 비밀은 이미 없으므로 거기서 시도하면 실패 기록이 옛 seq 에 붙고 새 것은 묻힌다. 진단 보고서(#535)가 그 선택·실패
    /// 사유·방/초대 상태를 담는지도 여기서 본다(가짜 엔진이라 join 은 notJoined 로 끝난다).
    func testOnlyTheNewestWelcomePerRoomIsTriedAndTheDiagnosticsReportSaysSo() async throws {
        let relay = CountingRelay()
        let (model, _, cursors) = makeModel(actor: "owner", relay: relay)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        let old = relay.inner.seedWelcome(room: "ops-yukson", target: model.deviceId)
        let newest = relay.inner.seedWelcome(room: "ops-yukson", target: model.deviceId)
        XCTAssertLessThan(old, newest)
        let listed = try await relay.lobbyWelcomes(device: model.deviceId)
        XCTAssertEqual(listed.map(\.seq), [old, newest], "the relay lists both unread Welcomes")

        await model.refresh()
        XCTAssertEqual(model.pendingInvites.map(\.seq), [newest], "only the newest Welcome of the room is an invite")
        XCTAssertEqual(model.inviteStates["ops-yukson"], AppModel.InviteState.failed(tries: 1, reason: Strings.notJoined))
        XCTAssertEqual(try cursors.cursor(room: "ops-yukson"), newest, "the sync read up to the newest Welcome")

        let report = model.diagnosticsReport(now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(report.hasPrefix("hande ios diagnostics 1970-01-01T00:00:00Z device=\(model.deviceId) actor=owner phase=ready"), report)
        XCTAssertTrue(report.contains("\nops-yukson: joined=false halted=false cursor=\(newest) epoch="), report)
        XCTAssertTrue(report.contains("\ninvites:\nops-yukson: seq \(newest) epoch 2 failed 1x (\(Strings.notJoined))"), report)
        XCTAssertTrue(report.contains("lobby: 2 welcomes, 1 older per-room duplicates ignored"), report)
        XCTAssertTrue(report.contains("lobby ops-yukson: adopt failed seq \(newest) try 1 — \(Strings.notJoined)"), report)
        XCTAssertFalse(report.contains("adopt failed seq \(old)"), "the stale Welcome was never tried")
        XCTAssertTrue(report.contains("lobby replenish: live 8 protect 0 prune=true"), report)
        XCTAssertFalse(report.contains("Bearer"), "no credential material in the report")
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
