// LobbyKeyring 테스트 (#380 P5-3) — 가짜 엔진(key_package 상한 8 · delete_key_package · join 이 비밀을 요구하고 나머지를 지움)
// + FakeRelay 로비(기기당 live 상한, 가장 오래된 것부터 소비). 수용 기준(#380 5번 "앱: 보충 단위 테스트"):
//   보충이 목표까지 만들어 게시하고 장부를 남긴다 · 소비된 만큼 장부 앞쪽의 로컬 비밀을 지우고 다시 채운다 · 서버 상한을 넘지 않는다 ·
//   게시 실패면 새 비밀을 버린다 · 로비 없는 릴레이(404)는 그대로 던진다 · adoptRoom 으로 바꾼 방 상태만 로비 Welcome 을 join 한다.
import XCTest
@testable import FamilyMLSCore

final class LobbyKeyringTests: XCTestCase {
    let me = "owner-iphone-aaaaaa"
    let bot = "bot-gongmyoung"

    private func keyring(_ h: SyncHarness) -> LobbyKeyring {
        LobbyKeyring(identity: h.me, engineFactory: h.factory, stateStore: h.store, transport: h.relay, lockTimeout: 1) { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()   // 테스트 ref: hex(bytes) — 서버는 비어 있지 않은 문자열이면 받는다
        }
    }

    private func loadSlot(_ h: SyncHarness) throws -> LobbySlot? {
        try h.store.inner.withExclusive(room: LobbyKeyring.slot, timeout: 1) { tx in try tx.load().map(LobbyKeyring.decode) }
    }

    private func slotEngine(_ h: SyncHarness) throws -> FakeEngineState? {
        try loadSlot(h).map { FakeEngineState.decode($0.state) }
    }

    func testReplenishMintsUpToTargetAndKeepsLedger() async throws {
        let h = try SyncHarness(me: me)
        let report = try await keyring(h).replenish(target: 8)
        XCTAssertEqual(report, LobbyReport(live: 8, max: 8, minted: 8, pruned: 0))
        XCTAssertEqual(h.relay.lobbyLive[me]?.count, 8)
        XCTAssertEqual(h.relay.lobbyPosts.count, 1, "one POST with all fresh packages")
        let slot = try XCTUnwrap(try loadSlot(h))
        XCTAssertEqual(slot.published.count, 8)
        XCTAssertEqual(slot.published, h.relay.lobbyPosts[0].packages.map(\.bytes), "ledger = what the relay accepted, in order")
        XCTAssertEqual(try slotEngine(h)?.keyPackages?.count, 8, "the slot holds the private material")
        XCTAssertNil(try slotEngine(h)?.members, "the slot never joins a group")
        XCTAssertTrue(h.relay.violations.isEmpty, "network outside the transaction")

        // 이미 충분하면 아무것도 하지 않는다.
        let again = try await keyring(h).replenish(target: 8)
        XCTAssertEqual(again, LobbyReport(live: 8, max: 8, minted: 0, pruned: 0))
        XCTAssertEqual(h.relay.lobbyPosts.count, 1)
    }

    func testReplenishAfterConsumptionPrunesOldestAndRefills() async throws {
        let h = try SyncHarness(me: me)
        try await keyring(h).replenish(target: 8)
        let before = try XCTUnwrap(try loadSlot(h)).published
        // 봇이 두 방에서 하나씩 소비(가장 오래된 것부터).
        _ = try await h.relay.consumeLobbyKeyPackage(device: bot, target: me, room: "ops-a")
        _ = try await h.relay.consumeLobbyKeyPackage(device: bot, target: me, room: "ops-b")
        XCTAssertEqual(h.relay.lobbyLive[me]?.count, 6)

        let report = try await keyring(h).replenish(target: 8)
        XCTAssertEqual(report, LobbyReport(live: 8, max: 8, minted: 2, pruned: 2))
        let after = try XCTUnwrap(try loadSlot(h)).published
        XCTAssertEqual(after.count, 8)
        XCTAssertEqual(Array(after.prefix(6)), Array(before.dropFirst(2)), "the two oldest left the ledger, the rest kept their order")
        XCTAssertEqual(try slotEngine(h)?.keyPackages?.count, 8, "local cap respected: 2 deleted, 2 minted")
        XCTAssertFalse(try XCTUnwrap(try slotEngine(h)?.keyPackages).contains(before[0]), "consumed private material is gone")
    }

    func testReplenishRespectsServerMax() async throws {
        let h = try SyncHarness(me: me)
        h.relay.lobbyMax = 4
        let report = try await keyring(h).replenish(target: 8)
        XCTAssertEqual(report, LobbyReport(live: 4, max: 4, minted: 4, pruned: 0))
        XCTAssertEqual(try slotEngine(h)?.keyPackages?.count, 4)
    }

    func testPublishFailureDropsFreshSecrets() async throws {
        let h = try SyncHarness(me: me)
        h.relay.lobbyPostErrors = [.network("down")]
        await XCTAssertThrowsErrorAsync(try await self.keyring(h).replenish(target: 8)) { XCTAssertEqual($0 as? RelayError, .network("down")) }
        XCTAssertEqual(try slotEngine(h)?.keyPackages?.count ?? 0, 0, "nothing the relay did not accept stays local")
        XCTAssertEqual(try loadSlot(h)?.published.count ?? 0, 0)
        // 다음 보충이 다시 만든다.
        let report = try await keyring(h).replenish(target: 8)
        XCTAssertEqual(report.minted, 8)
    }

    func testRelayWithoutLobbyThrows404() async throws {
        let h = try SyncHarness(me: me)
        h.relay.lobbyEnabled = false
        await XCTAssertThrowsErrorAsync(try await self.keyring(h).replenish(target: 8)) {
            XCTAssertEqual($0 as? RelayError, .refused(code: "not_found", status: 404))
        }
        XCTAssertNil(try loadSlot(h), "no slot is created when the relay has no lobby")
        XCTAssertFalse(try keyring(h).adoptRoom("ops-a"), "nothing to adopt from")
    }

    /// 핵심 왕복: 로비 key package 로 만든 Welcome 은 identity 시드로 시작한 방 상태로는 열 수 없고(파사드 제약),
    /// `adoptRoom` 으로 `_lobby` 상태를 복사한 뒤 커서를 되감으면 기존 RoomSyncEngine 이 join 한다.
    func testAdoptRoomLetsSyncJoinALobbyWelcome() async throws {
        let h = try SyncHarness(me: me)
        try await keyring(h).replenish(target: 8)
        let consumed = try XCTUnwrap(try await h.relay.consumeLobbyKeyPackage(device: bot, target: me, room: h.room))
        h.relay.inject(device: bot, kind: .commit, bytes: FakeCommit(committer: bot, adds: [me]).bytes)
        let welcomeSeq = h.relay.inject(device: bot, kind: .welcome, bytes: FakeWelcome(members: [bot, me], keyPackage: consumed.bytes).bytes)
        h.relay.members = [bot, me]

        // ① 모르는 방을 그냥 동기화하면: 상태는 identity 시드(key package 없음) → join 거부 → 커서는 Welcome 을 지난다.
        let first = try await h.sync.syncOnce()
        XCTAssertFalse(first.joined)
        XCTAssertEqual(first.rejected, [welcomeSeq])
        XCTAssertEqual(try h.cursors.cursor(room: h.room), welcomeSeq)

        // ② adopt: 방 상태 = 로비 슬롯 상태(비밀 포함), 커서 되감기, 동기화 객체 새로.
        XCTAssertFalse(try keyring(h).isMember(room: h.room))
        XCTAssertTrue(try keyring(h).adoptRoom(h.room))
        try h.cursors.setCursor(room: h.room, seq: welcomeSeq - 1)
        let second = try await h.restart().syncOnce()
        XCTAssertTrue(second.joined, "the adopted state holds the consumed key package's secret")
        XCTAssertEqual(h.engineState?.members, [bot, me].sorted())
        XCTAssertNil(h.engineState?.keyPackages, "join pruned the room copy")
        XCTAssertEqual(try slotEngine(h)?.keyPackages?.count, 8, "the lobby slot itself is untouched")
        XCTAssertEqual(try h.cursors.cursor(room: h.room), welcomeSeq)

        // ③ 이미 참여한 방은 다시 바꾸지 않는다.
        XCTAssertTrue(try keyring(h).isMember(room: h.room))
        XCTAssertFalse(try keyring(h).adoptRoom(h.room))
        XCTAssertEqual(h.engineState?.members, [bot, me].sorted())
    }

    func testAdoptRoomOverwritesAGrouplessState() async throws {
        let h = try SyncHarness(me: me)
        try await keyring(h).replenish(target: 2)
        try h.store.seed(room: "ops-x", FakeEngineState())   // identity 시드로 만들어진(그룹 없는) 상태
        XCTAssertTrue(try keyring(h).adoptRoom("ops-x"))
        XCTAssertEqual(try h.store.engineState(room: "ops-x")?.keyPackages?.count, 2)
        XCTAssertFalse(try keyring(h).adoptRoom(LobbyKeyring.slot), "the slot itself is never a room")
    }

    func testSlotRoundTripsThroughJSON() throws {
        let slot = LobbySlot(state: Data([1, 2, 3]), published: [Data([9]), Data([8, 7])])
        XCTAssertEqual(try LobbyKeyring.decode(try LobbyKeyring.encode(slot)), slot)
        XCTAssertThrowsError(try LobbyKeyring.decode(Data("nope".utf8)))
    }
}
