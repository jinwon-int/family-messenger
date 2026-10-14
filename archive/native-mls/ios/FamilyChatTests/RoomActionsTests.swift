// §12-E 방 만들기·초대 화면의 모델 쪽 + 가족 투입 선행(사용자 이름 actor) — 가짜 엔진(FakeFactory, AppModelTests.swift).
// 실 엔진의 만들기→초대→참여 왕복은 CrossProcessTests·TwoDeviceScenario 가 이미 덮는다.
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class RoomActionsTests: XCTestCase {
    private func deps(actor: String?, identity: @escaping () -> DeviceID, defaultRoom: RoomID? = nil) -> AppModel.Dependencies {
        var d = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: InMemoryStateStore(), messageStore: InMemoryMessageStore(),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: identity, expectedDecryptFormat: { 2 }, makeTransport: { _ in InMemoryRelay() })
        d.actorStore = InMemoryActorStore(actor)
        if let defaultRoom { d.defaultRoom = defaultRoom }
        return d
    }

    // MARK: 사용자 이름(actor)

    func testFreshInstallAsksForActorBeforeCreatingIdentity() async {
        var identityCalls = 0
        let store = InMemoryActorStore(nil)
        var d = deps(actor: nil, identity: { identityCalls += 1; return "mom-iphone-a1b2c3" })
        d.actorStore = store
        let model = AppModel(dependencies: d)
        await model.bootstrap()
        XCTAssertEqual(model.phase, .needsActor)
        XCTAssertEqual(identityCalls, 0, "no device id (and no MLS identity) before the actor is chosen")

        let rejected = await model.chooseActor("mo-m")
        XCTAssertFalse(rejected)
        XCTAssertEqual(model.phase, .needsActor)
        XCTAssertEqual(model.lastError, Strings.actorInvalid)
        XCTAssertNil(store.actor)

        let accepted = await model.chooseActor("  Mom ")
        XCTAssertTrue(accepted)
        XCTAssertEqual(store.actor, "mom", "trimmed and lowercased")
        XCTAssertEqual(model.phase, .needsLogin)
        XCTAssertEqual(model.deviceId, "mom-iphone-a1b2c3")
        XCTAssertEqual(identityCalls, 1)
        XCTAssertNil(model.lastError)
    }

    func testExistingInstallSkipsActorSetup() async {
        let model = AppModel(dependencies: deps(actor: "owner", identity: { "owner-iphone-27a879" }))
        await model.bootstrap()
        XCTAssertEqual(model.phase, .needsLogin)
        let late = await model.chooseActor("dad")
        XCTAssertFalse(late, "the actor can only be chosen once, before the identity exists")
    }

    func testDefaultRoomComesFromDependencies() async {
        XCTAssertEqual(AppModel(dependencies: deps(actor: "owner", identity: { "owner-iphone-1" })).defaultRoom, "family-acc")
        XCTAssertEqual(AppModel(dependencies: deps(actor: "owner", identity: { "owner-iphone-1" }, defaultRoom: "family")).defaultRoom, "family")
    }

    func testCreateRoomListsTheRoomAtOnce() async throws {
        let model = AppModel(dependencies: deps(actor: "owner", identity: { "owner-iphone-1" }))
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertTrue(model.canRequestJoin)
        try await model.createRoom(room: "family-new")
        XCTAssertEqual(model.rooms.map(\.room), ["family-new"])
    }

    // MARK: 문구·ID 규칙

    func testMembershipFailureMessages() {
        XCTAssertTrue(Strings.membershipFailure(MembershipError.noKeyPackage("mom-iphone-1a2b3c")).contains("mom-iphone-1a2b3c"))
        XCTAssertTrue(Strings.membershipFailure(MembershipError.noKeyPackage("x")).contains("참여 요청"))
        XCTAssertEqual(Strings.membershipFailure(RelayError.unauthorized), Strings.sessionExpired)
        XCTAssertTrue(Strings.membershipFailure(RelayError.cas(epoch: 3, revision: 1)).contains("새로고침"))
        XCTAssertTrue(Strings.membershipFailure(RelayError.refused(code: "room_closed", status: 410)).contains("room_closed"))
        XCTAssertNotEqual(Strings.membershipFailure(MembershipError.notInGroup), Strings.membershipFailure(MembershipError.alreadyInGroup))
    }

    func testActorNameRules() {
        for ok in ["mom", "dad", "jiyu", "owner", "a1", "kid2026"] { XCTAssertTrue(ActorName.isValid(ok), ok) }
        for bad in ["", "m", "Mom", "1mom", "mo-m", "mo m", "mom_", "엄마", String(repeating: "a", count: 17)] {
            XCTAssertFalse(ActorName.isValid(bad), bad)
        }
        XCTAssertEqual(ActorName.of(deviceId: "owner-iphone-27a879"), "owner")
        XCTAssertNil(ActorName.of(deviceId: "noprefix"))
        XCTAssertNil(ActorName.of(deviceId: "Bad-iphone-1"))
    }

    func testRoomAndDeviceNameRules() {
        for ok in ["family-acc", "f", "0room", "a-b-c"] { XCTAssertTrue(RoomName.isValid(ok), ok) }
        for bad in ["", "-room", "Room", "room_1", "방", String(repeating: "a", count: 49)] { XCTAssertFalse(RoomName.isValid(bad), bad) }
        for ok in ["owner-iphone-27a879", "bot-gongmyoung", "owner_pc", "A1"] { XCTAssertTrue(DeviceName.isValid(ok), ok) }
        for bad in ["", "owner iphone", "기기", "a/b", String(repeating: "a", count: 65)] { XCTAssertFalse(DeviceName.isValid(bad), bad) }
    }

    // MARK: 기기 ID 저장(live 경로)

    func testExistingDeviceIdIsKeptWhatEverTheActorAndActorIsDerivedFromIt() throws {
        let suite = "hande.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = DefaultsActorStore(defaults: defaults)
        XCTAssertNil(store.actor, "fresh install: nothing chosen yet")
        let fresh = DeviceIdentity.existingOrNew(actor: "mom", defaults: defaults)
        XCTAssertTrue(fresh.hasPrefix("mom-iphone-"), fresh)
        XCTAssertEqual(store.actor, "mom", "derived from the stored device id")
        XCTAssertEqual(DeviceIdentity.existingOrNew(actor: "dad", defaults: defaults), fresh, "one device per install")

        let legacy = "hande.tests.\(UUID().uuidString)"
        let old = try XCTUnwrap(UserDefaults(suiteName: legacy))
        defer { old.removePersistentDomain(forName: legacy) }
        old.set("owner-iphone-27a879", forKey: DeviceIdentity.defaultsKey)   // install from before this change
        XCTAssertEqual(DefaultsActorStore(defaults: old).actor, "owner", "existing owner phone skips the actor screen")
        DefaultsActorStore(defaults: old).save("dad")
        XCTAssertEqual(DefaultsActorStore(defaults: old).actor, "dad", "an explicit choice wins over the derived one")
    }
}
