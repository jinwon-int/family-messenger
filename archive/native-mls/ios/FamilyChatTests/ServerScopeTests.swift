// 서버 저장·해석(`ServerStore`)·서버별 스코프(`ServerScope`/`ScopedDefaults`)·옛 설치 이관(`LegacyScopeMigration`) — #584 PR 2.
// UserDefaults 는 테스트 suite, 파일은 임시 디렉터리, 자격증명은 메모리 저장소(Keychain·App Group 은 실기기 몫). Linux 스모크에도 복사된다.
import XCTest
import FamilyMLSCore
@testable import FamilyChat

final class ServerScopeTests: XCTestCase {
    private var suites: [String] = []
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fc-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: root)
    }

    private func defaults() throws -> UserDefaults {
        let suite = "hande.tests.scope.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: ServerStore — 저장·해석

    func testResolvePrefersSelectionThenClearedThenBuildDefault() {
        let chosen = ServerSelection(baseURL: url("https://relay.example.com"), name: "집", discoveredVia: .wellKnown, selectedAt: Date(timeIntervalSince1970: 1))
        let fallback = url("https://default.example.com")
        XCTAssertEqual(ServerStore.resolve(.selected(chosen), defaultURL: fallback), chosen)
        XCTAssertNil(ServerStore.resolve(.cleared, defaultURL: fallback), "「서버 바꾸기」 뒤에는 기본값으로 되돌아가지 않는다")
        let adopted = ServerStore.resolve(.unset, defaultURL: fallback, now: Date(timeIntervalSince1970: 7))
        XCTAssertEqual(adopted, ServerSelection(baseURL: fallback, name: nil, discoveredVia: .buildDefault, selectedAt: Date(timeIntervalSince1970: 7)))
        XCTAssertNil(ServerStore.resolve(.unset, defaultURL: nil), "App Store build without a default → server screen")
    }

    func testDefaultsServerStoreRoundTripAndClear() throws {
        let store = DefaultsServerStore(defaults: try defaults())
        XCTAssertEqual(store.load(), .unset)
        let chosen = ServerSelection(baseURL: url("https://relay.example.com"), name: "집", discoveredVia: .wellKnown, selectedAt: Date(timeIntervalSince1970: 1_700_000_000))
        store.save(chosen)
        XCTAssertEqual(store.load(), .selected(chosen))
        store.clear()
        XCTAssertEqual(store.load(), .cleared)
        store.save(chosen)
        XCTAssertEqual(store.load(), .selected(chosen), "saving again drops the cleared marker")
    }

    func testServerSelectionJSONShape() throws {
        let chosen = ServerSelection(baseURL: url("https://relay.example.com"), name: "집", discoveredVia: .direct, selectedAt: Date(timeIntervalSince1970: 0))
        let json = String(decoding: try ServerStore.encode(chosen), as: UTF8.self)
        XCTAssertEqual(json, #"{"baseURL":"https://relay.example.com","discoveredVia":"direct","name":"집","selectedAt":"1970-01-01T00:00:00Z"}"#)
        XCTAssertEqual(ServerStore.decode(Data(json.utf8)), chosen)
        XCTAssertNil(ServerStore.decode(Data("{}".utf8)))
        XCTAssertEqual(ServerStore.key, "hande.server")
    }

    // MARK: ServerScope — 식별자·경로·키

    func testScopeIdIsStableAndCanonical() {
        let a = ServerScope(baseURL: url("https://relay.example.com"))
        XCTAssertEqual(a.id.count, 16)
        XCTAssertTrue(a.id.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }, a.id)
        XCTAssertEqual(ServerScope(baseURL: url("https://Relay.Example.com/")), a, "scheme/host case and trailing slash do not change the scope")
        XCTAssertEqual(ServerScope(baseURL: url("HTTPS://relay.example.com")), a)
        XCTAssertNotEqual(ServerScope(baseURL: url("https://relay.example.com:8443")), a, "port is part of the server")
        XCTAssertNotEqual(ServerScope(baseURL: url("https://relay.example.com/relay")), a, "path is part of the server")
        XCTAssertNotEqual(ServerScope(baseURL: url("https://other.example.com")), a)
        XCTAssertEqual(ServerScope.canonical(url("https://Relay.Example.com:8443/relay/")), "https://relay.example.com:8443/relay")
    }

    func testScopePathsKeysAndKeychainAccount() {
        let scope = ServerScope(baseURL: url("https://relay.example.com"))
        XCTAssertEqual(scope.directory(in: root), root.appendingPathComponent("servers", isDirectory: true).appendingPathComponent(scope.id, isDirectory: true))
        XCTAssertEqual(scope.key("familychat.deviceId"), "familychat.deviceId.\(scope.id)")
        XCTAssertEqual(scope.keychainAccount, "v1.\(scope.id)")
        XCTAssertEqual(ServerScope.legacyKeychainAccount, "v1")
    }

    func testScopedDefaultsKeepServersApart() throws {
        let base = try defaults()
        let a = ServerScope(baseURL: url("https://a.example.com")).defaults(base)
        let b = ServerScope(baseURL: url("https://b.example.com")).defaults(base)
        let legacy = ScopedDefaults(base)
        a.set("mom-iphone-aaaaaa", forKey: DeviceIdentity.defaultsKey)
        XCTAssertNil(b.string(forKey: DeviceIdentity.defaultsKey))
        XCTAssertNil(legacy.string(forKey: DeviceIdentity.defaultsKey))
        XCTAssertEqual(base.string(forKey: a.key(DeviceIdentity.defaultsKey)), "mom-iphone-aaaaaa")
        // 기기 ID·actor·푸시 기록·표시 설정이 스코프를 통해 간다
        XCTAssertEqual(DeviceIdentity.existingOrNew(actor: "dad", defaults: b).hasPrefix("dad-iphone-"), true)
        XCTAssertEqual(DeviceIdentity.existingOrNew(actor: "dad", defaults: a), "mom-iphone-aaaaaa", "a's device id is untouched by b")
        XCTAssertEqual(DefaultsActorStore(defaults: a).actor, "mom")
        XCTAssertEqual(DefaultsActorStore(defaults: b).actor, "dad")
        let records = UserDefaultsPushRecordStore(defaults: a)
        records.save(PushRegistrationRecord(device: "mom-iphone-aaaaaa", token: Data([1]), topic: "t", registeredAt: Date(timeIntervalSince1970: 1)))
        XCTAssertNotNil(records.load())
        XCTAssertNil(UserDefaultsPushRecordStore(defaults: b).load())
        XCTAssertNil(UserDefaultsPushRecordStore(defaults: base).load(), "legacy (unscoped) key stays empty")
        DeviceIdentity.reset(defaults: a)
        XCTAssertNil(a.string(forKey: DeviceIdentity.defaultsKey))
        XCTAssertNotNil(b.string(forKey: DeviceIdentity.defaultsKey), "reset is per scope")
    }

    @MainActor
    func testLocalPrefsAreScoped() async throws {
        let base = try defaults()
        let a = LocalPrefs(defaults: ServerScope(baseURL: url("https://a.example.com")).defaults(base))
        a.markRead("family", seq: 7)
        a.setOrder(["family", "x"])
        let again = LocalPrefs(defaults: ServerScope(baseURL: url("https://a.example.com")).defaults(base))
        XCTAssertEqual(again.readSeq["family"], 7)
        XCTAssertEqual(again.roomOrder, ["family", "x"])
        let b = LocalPrefs(defaults: ServerScope(baseURL: url("https://b.example.com")).defaults(base))
        XCTAssertTrue(b.readSeq.isEmpty); XCTAssertTrue(b.roomOrder.isEmpty)
    }

    // MARK: 옛 설치 이관

    func testLegacyMigrationMovesEverythingOnceIntoTheDefaultScope() throws {
        let shared = try defaults()
        let local = try defaults()
        let scope = ServerScope(baseURL: url("https://relay.example.com"))
        // 옛 자리: 파일(mls/, messages.db + sidecar), 공유 키, 앱 전용 키, Keychain account v1
        let mls = root.appendingPathComponent("mls", isDirectory: true)
        try FileManager.default.createDirectory(at: mls, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: mls.appendingPathComponent("family.state"))
        try Data("db".utf8).write(to: root.appendingPathComponent("messages.db"))
        try Data("wal".utf8).write(to: root.appendingPathComponent("messages.db-wal"))
        shared.set("owner-iphone-27a879", forKey: DeviceIdentity.defaultsKey)
        shared.set("owner", forKey: DefaultsActorStore.key)
        local.set(["family": NSNumber(value: 9)], forKey: LocalPrefs.readKey)
        local.set(["family"], forKey: LocalPrefs.orderKey)
        local.set(Data("rec".utf8), forKey: UserDefaultsPushRecordStore.key)
        let legacyCredentials = InMemoryCredentialStore(.accessCookie("jwt"))
        let scopedCredentials = InMemoryCredentialStore()
        XCTAssertTrue(LegacyScopeMigration.hasLegacyData(root: root, shared: shared, local: local, legacyCredentials: legacyCredentials))

        let report = LegacyScopeMigration.run(root: root, scope: scope, shared: shared, local: local,
                                              legacyCredentials: legacyCredentials, scopedCredentials: scopedCredentials)
        XCTAssertEqual(report.movedFiles, ["mls", "messages.db", "messages.db-wal"])
        XCTAssertEqual(Set(report.movedKeys), [DeviceIdentity.defaultsKey, DefaultsActorStore.key, UserDefaultsPushRecordStore.key, LocalPrefs.readKey, LocalPrefs.orderKey])
        XCTAssertTrue(report.movedCredential)

        let target = scope.directory(in: root)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("mls/family.state")), Data("state".utf8))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("messages.db")), Data("db".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mls.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("messages.db").path))
        let scopedShared = scope.defaults(shared)
        XCTAssertEqual(scopedShared.string(forKey: DeviceIdentity.defaultsKey), "owner-iphone-27a879")
        XCTAssertEqual(DefaultsActorStore(defaults: scopedShared).actor, "owner")
        XCTAssertNil(shared.string(forKey: DeviceIdentity.defaultsKey), "legacy key removed")
        XCTAssertNil(shared.string(forKey: DefaultsActorStore.key))
        let scopedLocal = scope.defaults(local)
        XCTAssertEqual((scopedLocal.dictionary(forKey: LocalPrefs.readKey) as? [String: NSNumber])?["family"]?.int64Value, 9)
        XCTAssertEqual(scopedLocal.stringArray(forKey: LocalPrefs.orderKey), ["family"])
        XCTAssertEqual(scopedLocal.data(forKey: UserDefaultsPushRecordStore.key), Data("rec".utf8))
        XCTAssertNil(local.object(forKey: LocalPrefs.readKey))
        XCTAssertEqual(scopedCredentials.load(), .accessCookie("jwt"))
        XCTAssertNil(legacyCredentials.load())
        XCTAssertFalse(LegacyScopeMigration.hasLegacyData(root: root, shared: shared, local: local, legacyCredentials: legacyCredentials))

        // 두 번째 실행: 아무것도 없다 — no-op
        let second = LegacyScopeMigration.run(root: root, scope: scope, shared: shared, local: local,
                                              legacyCredentials: legacyCredentials, scopedCredentials: scopedCredentials)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("messages.db")), Data("db".utf8))
    }

    func testLegacyMigrationNeverOverwritesAnExistingScope() throws {
        let shared = try defaults()
        let local = try defaults()
        let scope = ServerScope(baseURL: url("https://relay.example.com"))
        let target = scope.directory(in: root)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: target.appendingPathComponent("messages.db"))
        try Data("old".utf8).write(to: root.appendingPathComponent("messages.db"))
        shared.set("owner-iphone-old000", forKey: DeviceIdentity.defaultsKey)
        scope.defaults(shared).set("owner-iphone-new000", forKey: DeviceIdentity.defaultsKey)
        let scopedCredentials = InMemoryCredentialStore(.bearer("new"))
        let legacyCredentials = InMemoryCredentialStore(.bearer("old"))

        let report = LegacyScopeMigration.run(root: root, scope: scope, shared: shared, local: local,
                                              legacyCredentials: legacyCredentials, scopedCredentials: scopedCredentials)
        XCTAssertTrue(report.movedFiles.isEmpty, "scoped messages.db exists → legacy file left where it is")
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("messages.db")), Data("new".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("messages.db").path))
        XCTAssertEqual(scope.defaults(shared).string(forKey: DeviceIdentity.defaultsKey), "owner-iphone-new000")
        XCTAssertNil(shared.string(forKey: DeviceIdentity.defaultsKey), "legacy key is still removed so it cannot resurrect")
        XCTAssertEqual(scopedCredentials.load(), .bearer("new"))
        XCTAssertNil(legacyCredentials.load(), "legacy credential is dropped when the scope already has one")
        XCTAssertFalse(report.movedCredential)
    }

    func testMigrationKeyListsMatchTheStoresThatUseThem() {
        // ServerScope.swift 머리말·LegacyScopeMigration 의 목록이 실제 저장소 키와 어긋나지 않게.
        XCTAssertEqual(LegacyScopeMigration.sharedKeys, ["familychat.deviceId", "familychat.actor"])
        XCTAssertEqual(LegacyScopeMigration.localKeys, ["familychat.push.registration.v1", "hande.readSeq", "hande.roomOrder"])
        XCTAssertEqual(LegacyScopeMigration.fileNames.first, "mls")
        XCTAssertTrue(LegacyScopeMigration.fileNames.contains("messages.db"))
    }
}
