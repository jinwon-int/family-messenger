// #715 room-order v1 — AppModel 배선: 업데이트 뒤 첫 실행의 시드(이 아이폰의 저장 순서) · 서버 순서 채택 · 사용자 변경 PUT · 409 채택 ·
// 404 세션 끄기 · 60초 간격 · 네트워크 오류 재시도. 판정 자체는 Core `RoomOrderSyncTests`(Linux) — 여기는 왕복과 `LocalPrefs` 반영만.
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class RoomOrderSyncAppTests: XCTestCase {
    private final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    /// 릴레이에 있는 두 방(family · work, 기본 순서 그대로)과 이 기기 표시 설정(일회용 suite). `saved` = 업데이트 전부터 있던 아이폰의 순서.
    private func readyModel(relay: InMemoryRelay, clock: Clock, saved: [RoomID]) async throws -> AppModel {
        let rooms = [RoomRecord(room: "family", epoch: 0, revision: 0, haltedReason: nil, displayOrder: 0),
                     RoomRecord(room: "work", epoch: 0, revision: 0, haltedReason: nil, displayOrder: 1)]
        var deps = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: InMemoryStateStore(), messageStore: InMemoryMessageStore(seedRooms: rooms),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "owner-iphone-abc123" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        deps.clock = { clock.now }
        let suite = "room-order-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        deps.localDefaults = ScopedDefaults(defaults)
        if !saved.isEmpty { LocalPrefs(defaults: deps.localDefaults).setOrder(saved) }   // 지난 버전이 저장해 둔 `hande.roomOrder`
        for (n, room) in ["family", "work"].enumerated() {
            _ = try await relay.postEvent(room: room, EventPost(device: "mom-iphone-1", clientId: "mom-iphone-1-c\(n)", kind: .application,
                                                                epoch: 0, bytes: Data("hi".utf8)))
        }
        let model = AppModel(dependencies: deps)
        await model.bootstrap()
        model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        await model.roomOrderSettled()
        return model
    }

    /// 업데이트 뒤 첫 실행: 릴레이에 순서가 없다(revision 0) → 이 아이폰의 저장 순서(오너 기준)가 base 0 으로 올라가 시드가 된다.
    func testFirstLaunchAfterUpdateSeedsTheExistingLocalOrder() async throws {
        let relay = InMemoryRelay(); relay.roomOrderRoute = true
        let model = try await readyModel(relay: relay, clock: Clock(), saved: ["work", "family"])
        XCTAssertEqual(relay.roomOrderGets, 1)
        XCTAssertEqual(relay.roomOrderPuts, [RoomOrderPut(device: model.deviceId, rooms: ["work", "family"], baseRevision: 0)])
        XCTAssertEqual(relay.roomOrderState(actor: "owner"), RoomOrderState(rooms: ["work", "family"], revision: 1, updatedAt: 1_800_000_000))
        XCTAssertEqual(model.localPrefs.roomOrder, ["work", "family"], "the local order stays as it was")
        XCTAssertEqual(model.roomOrderSync.revision, 1)
    }

    /// 사용자 순서가 없는 기기는 시드하지 않는다(기본 순서는 사용자 순서가 아니다).
    func testNoLocalOrderDoesNotSeed() async throws {
        let relay = InMemoryRelay(); relay.roomOrderRoute = true
        let model = try await readyModel(relay: relay, clock: Clock(), saved: [])
        XCTAssertEqual(relay.roomOrderGets, 1)
        XCTAssertTrue(relay.roomOrderPuts.isEmpty)
        XCTAssertTrue(model.localPrefs.roomOrder.isEmpty)
    }

    /// 서버에 순서가 있으면(revision > 0) 로컬을 덮고, 그 뒤 사용자 변경은 마지막 revision 을 base 로 올린다.
    func testServerOrderIsAdoptedThenReorderPutsWithLastRevision() async throws {
        let relay = InMemoryRelay(); relay.roomOrderRoute = true
        relay.setRoomOrder(actor: "owner", rooms: ["family", "work"], revision: 3)
        let model = try await readyModel(relay: relay, clock: Clock(), saved: ["work", "family"])
        XCTAssertEqual(model.localPrefs.roomOrder, ["family", "work"], "revision > 0 → the relay's order wins")
        XCTAssertTrue(relay.roomOrderPuts.isEmpty)
        model.setRoomOrder(["work", "family"])
        XCTAssertEqual(model.localPrefs.roomOrder, ["work", "family"], "applied locally at once")
        await model.roomOrderSettled()
        XCTAssertEqual(relay.roomOrderPuts, [RoomOrderPut(device: model.deviceId, rooms: ["work", "family"], baseRevision: 3)])
        XCTAssertEqual(relay.roomOrderState(actor: "owner").revision, 4)
        XCTAssertEqual(model.roomOrderSync.revision, 4)
    }

    /// 다른 기기가 먼저 바꿨다 → 409 → 서버 순서를 채택해 다시 그린다.
    func testConflictAdoptsTheRelayOrder() async throws {
        let relay = InMemoryRelay(); relay.roomOrderRoute = true
        relay.setRoomOrder(actor: "owner", rooms: ["family", "work"], revision: 3)
        let model = try await readyModel(relay: relay, clock: Clock(), saved: [])
        XCTAssertEqual(model.localPrefs.roomOrder, ["family", "work"])
        relay.setRoomOrder(actor: "owner", rooms: ["family", "work"], revision: 4)   // 웹에서 바꿨다가 되돌림 — revision 만 앞섰다
        model.setRoomOrder(["work", "family"])
        await model.roomOrderSettled()
        XCTAssertEqual(relay.roomOrderPuts.last?.baseRevision, 3)
        XCTAssertEqual(model.localPrefs.roomOrder, ["family", "work"], "409 → the relay's current order")
        XCTAssertEqual(relay.roomOrderState(actor: "owner").revision, 4, "the conflicting PUT stored nothing")
        XCTAssertEqual(model.roomOrderSync.revision, 4)
    }

    /// 옛 릴레이(404): 이 세션은 로컬만 — 바꾼 순서는 저장되고, 다시 묻지 않는다.
    func testOldRelayKeepsLocalOrderOnlyForTheSession() async throws {
        let relay = InMemoryRelay()   // roomOrderRoute = false → 404
        let clock = Clock()
        let model = try await readyModel(relay: relay, clock: clock, saved: ["work", "family"])
        XCTAssertEqual(relay.roomOrderGets, 1)
        XCTAssertTrue(model.roomOrderSync.unsupported)
        model.setRoomOrder(["family", "work"])
        XCTAssertEqual(model.localPrefs.roomOrder, ["family", "work"])
        clock.now += 3600
        await model.foregrounded()
        model.requestRoomOrderSync()
        await model.roomOrderSettled()
        XCTAssertEqual(relay.roomOrderGets, 1, "404 is not asked again this session")
        XCTAssertTrue(relay.roomOrderPuts.isEmpty)
    }

    /// 목록 새로고침·전면 복귀는 마지막 GET 뒤 60초가 지나야 다시 묻는다. 다른 기기의 변경은 그때 채택된다.
    func testFetchIsAtLeast60SecondsApart() async throws {
        let relay = InMemoryRelay(); relay.roomOrderRoute = true
        relay.setRoomOrder(actor: "owner", rooms: ["family", "work"], revision: 1)
        let clock = Clock()
        let model = try await readyModel(relay: relay, clock: clock, saved: [])
        XCTAssertEqual(relay.roomOrderGets, 1)
        relay.setRoomOrder(actor: "owner", rooms: ["work", "family"], revision: 2)
        clock.now += 30
        model.requestRoomOrderSync()
        await model.foregrounded()
        await model.roomOrderSettled()
        XCTAssertEqual(relay.roomOrderGets, 1, "within 60 s — not asked")
        XCTAssertEqual(model.localPrefs.roomOrder, ["family", "work"])
        clock.now += 30
        model.requestRoomOrderSync()
        await model.roomOrderSettled()
        XCTAssertEqual(relay.roomOrderGets, 2)
        XCTAssertEqual(model.localPrefs.roomOrder, ["work", "family"], "the other device's order is adopted")
    }

    /// 네트워크 오류: 화면은 그대로, 다음 주기(≥60초)의 바퀴가 다시 묻고 시드한다.
    func testNetworkErrorRetriesNextCycle() async throws {
        let relay = InMemoryRelay(); relay.roomOrderRoute = true
        relay.failNextRoomOrderCalls([.network("offline")])
        let clock = Clock()
        let model = try await readyModel(relay: relay, clock: clock, saved: ["work", "family"])
        XCTAssertEqual(relay.roomOrderGets, 1)
        XCTAssertTrue(relay.roomOrderPuts.isEmpty)
        XCTAssertNil(model.lastError, "room-order failures never reach the screen")
        await model.refresh()
        await model.roomOrderSettled()
        XCTAssertEqual(relay.roomOrderGets, 1, "the next round inside 60 s does not ask again")
        clock.now += 60
        await model.refresh()
        await model.roomOrderSettled()
        XCTAssertEqual(relay.roomOrderGets, 2)
        XCTAssertEqual(relay.roomOrderPuts.map(\.baseRevision), [0])
        XCTAssertEqual(relay.roomOrderState(actor: "owner").rooms, ["work", "family"])
    }

    /// 로그아웃 → 다시 로그인은 새 세션: 404 기억·간격을 버리고 바로 묻는다.
    func testLoginStartsAFreshSession() async throws {
        let relay = InMemoryRelay(); relay.roomOrderRoute = true
        relay.setRoomOrder(actor: "owner", rooms: ["family", "work"], revision: 1)
        let model = try await readyModel(relay: relay, clock: Clock(), saved: [])
        XCTAssertEqual(relay.roomOrderGets, 1)
        await model.logout().value
        model.login(.bearer("t"))
        await model.refresh()
        await model.roomOrderSettled()
        XCTAssertEqual(relay.roomOrderGets, 2)
    }
}
