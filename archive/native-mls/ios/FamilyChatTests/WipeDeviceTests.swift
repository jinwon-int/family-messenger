// "이 기기 지우기"(`AppModel.wipeDevice`, §9-5) — 가짜 엔진 + 메모리 저장소(RemovableInMemoryStateStore, HaltRecoveryTests.swift) + 기록 릴레이.
// 파일 저장소·DB 의 실제 삭제는 Core `FileWipeTests`, Keychain·App Group 은 실기기 몫(증명하지 않음).
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class WipeDeviceTests: XCTestCase {
    private final class Fixture {
        let state = RemovableInMemoryStateStore()
        let messages = InMemoryMessageStore(seedRooms: [RoomRecord(room: "family", epoch: 2, revision: 1, haltedReason: nil, displayOrder: 0)])
        let credentials = InMemoryCredentialStore()
        let actors = InMemoryActorStore("mom")
        let relay = RecordingPushRelay()
        let pushRecords = InMemoryPushRecordStore()
        var identityCounter = 0
        var identityCleared = false
        var storageWiped = false

        @MainActor func makeModel() -> AppModel {
            var push = PushRegistrar.Dependencies(topic: "com.seoyoon-family.hande")
            push.records = pushRecords
            var deps = AppModel.Dependencies(
                engineFactory: FakeFactory(), stateStore: state, messageStore: messages,
                outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
                identityProvider: { [self] in "mom-iphone-\(String(format: "%06x", identityCounter))" },
                expectedDecryptFormat: { 2 }, makeTransport: { [relay] _ in relay }, push: push)
            deps.credentials = credentials
            deps.actorStore = actors
            deps.wipe.storage = { [self] in
                storageWiped = true
                try state.removeAllState(timeout: 1)
                messages.wipe()
            }
            deps.wipe.identity = { [self] in identityCleared = true; identityCounter += 1 }
            return AppModel(dependencies: deps)
        }
    }

    func testWipeDeviceDiscardsEverythingAndBecomesANewDevice() async throws {
        let f = Fixture()
        // 방 상태를 미리 심는다 — 가짜 릴레이는 이벤트가 없는 방에 404 를 주므로 동기화만으로는 방 상태 파일이 생기지 않는다.
        try f.state.withExclusive(room: "family", timeout: 1) { try $0.save(Data("old-group".utf8)) }
        let model = f.makeModel()
        await model.bootstrap(); model.login(.bearer("jwt")); await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.deviceId, "mom-iphone-000000")
        XCTAssertEqual(model.rooms.map(\.room), ["family"])
        XCTAssertNotNil(f.credentials.load(), "logged in: credential persisted")
        await model.pushTokenReceived(Data(repeating: 1, count: 32))
        XCTAssertEqual(f.relay.registrations.count, 1)
        XCTAssertEqual(try f.state.generation(room: Strings.identityRoom), 1)

        try await model.wipeDevice()

        XCTAssertEqual(f.relay.unregistrations, ["mom-iphone-000000"], "push DELETE for the old device, best effort")
        XCTAssertNil(f.pushRecords.load())
        XCTAssertTrue(f.storageWiped); XCTAssertTrue(f.identityCleared)
        XCTAssertTrue(f.state.removed.contains(Strings.identityRoom), "the identity slot (signing key) is gone")
        XCTAssertTrue(f.state.removed.contains("family"))
        XCTAssertNil(f.credentials.load(), "session gone")
        XCTAssertEqual(model.phase, .needsLogin, "a new device: login first, then enrolment")
        XCTAssertEqual(model.deviceId, "mom-iphone-000001", "fresh device id")
        XCTAssertEqual(model.rooms, [], "no rooms, no history")
        XCTAssertEqual(f.actors.actor, "mom", "the user name survives — same person, new device")
        XCTAssertEqual(try f.state.generation(room: Strings.identityRoom), 1, "a new identity was created and persisted once")
        XCTAssertEqual(model.fingerprint.count, 64)
        XCTAssertFalse(model.registrationJSON().isEmpty, "registration JSON for the operator is ready again")
        XCTAssertEqual(model.pushStatus, .off)
    }

    func testWipeDeviceBeforeLoginStillResetsIdentity() async throws {
        let f = Fixture()
        let model = f.makeModel()
        await model.bootstrap()
        XCTAssertEqual(model.phase, .needsLogin)
        try await model.wipeDevice()
        XCTAssertEqual(f.relay.unregistrations, [], "no transport: nothing to DELETE")
        XCTAssertEqual(model.deviceId, "mom-iphone-000001")
        XCTAssertEqual(model.phase, .needsLogin)
    }

    func testWipeDeviceIsIgnoredBeforeBootstrapAndOnFatal() async throws {
        let f = Fixture()
        let model = f.makeModel()
        try await model.wipeDevice()
        XCTAssertFalse(f.storageWiped, "nothing to wipe before bootstrap")
        XCTAssertEqual(model.phase, .starting)
    }

    func testWipeStorageFailureIsReportedToTheCaller() async {
        let f = Fixture()
        // 저장소 삭제가 실패하면 throw 한다 — 화면이 사유를 보이고 사용자가 다시 시도한다.
        var deps = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: f.state, messageStore: f.messages,
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-000000" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in nil })
        deps.actorStore = f.actors
        deps.wipe.storage = { throw StateStoreError.lockTimeout("family") }
        let failing = AppModel(dependencies: deps)
        await failing.bootstrap()
        do { try await failing.wipeDevice(); XCTFail("expected the storage error") }
        catch { XCTAssertEqual(error as? StateStoreError, .lockTimeout("family")) }
    }

    // MARK: 기기 ID 저장소

    func testDeviceIdentityResetClearsSuiteAndLegacyStandardCopy() throws {
        let suite = "hande.tests.wipe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = DeviceIdentity.existingOrNew(actor: "mom", defaults: defaults)
        UserDefaults.standard.set(old, forKey: DeviceIdentity.defaultsKey)   // 옛 설치가 standard 에 두던 사본
        defer { UserDefaults.standard.removeObject(forKey: DeviceIdentity.defaultsKey) }

        DeviceIdentity.reset(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: DeviceIdentity.defaultsKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: DeviceIdentity.defaultsKey), "the legacy copy cannot resurrect the old id")
        let fresh = DeviceIdentity.existingOrNew(actor: "mom", defaults: defaults)
        XCTAssertNotEqual(fresh, old)
        XCTAssertTrue(fresh.hasPrefix("mom-iphone-"))
    }
}
