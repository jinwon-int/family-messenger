// 통합(파이널라이저) — `Dependencies.live()` 조립(실 ios-ffi 엔진 · L1 FileStateStore/FileSQLiteStore · L3 RoomSyncEngine)
// 으로 2기기 시나리오를 메모리 릴레이 위에서 돌린다. 같은 시나리오를 실 Go 릴레이(HTTP) 위에서 도는 것은 RelaySmokeTests(#276).
import CryptoKit
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class IntegrationTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fc-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTwoDeviceScenarioOverInMemoryRelay() async throws {
        let relay = InMemoryRelay()
        try await TwoDeviceScenario(relay: relay, control: relay, root: root, room: "family").run()
    }

    /// D2: 방이 둘이어도 두 방 상태의 서명키는 identity 슬롯 하나다(등록 JSON·지문 1개).
    func testEveryRoomStateSharesTheIdentitySigningKey() async throws {
        let relay = InMemoryRelay()
        let device = ScenarioDevice(id: "owner-iphone-0a0b0c", base: relay, root: root)
        await device.model.bootstrap()
        device.model.login(.bearer("t"))
        try await device.model.requestJoin(room: "family")
        try await device.model.createRoom(room: "work")
        XCTAssertEqual(try device.roomFingerprint("family"), device.model.fingerprint)
        XCTAssertEqual(try device.roomFingerprint("work"), device.model.fingerprint)
        XCTAssertEqual(device.model.rooms.map(\.room), ["family", "work"])
        // 재시작해도 같은 신원·같은 방(파일 저장소 + 봉인).
        let fingerprint = device.model.fingerprint
        device.relaunch()
        await device.model.bootstrap()
        XCTAssertEqual(device.model.fingerprint, fingerprint)
        XCTAssertEqual(device.model.rooms.map(\.room), ["family", "work"])
    }

    /// 운영 봉인 키 경로(Keychain). 무서명 시뮬레이터에서 Keychain 이 막혀 있으면(-34018) 그 사실을 남기고 건너뛴다.
    func testKeychainSealKeyIsStableAcrossReads() throws {
        let service = "familychat.tests.\(UUID().uuidString)"
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        let source = KeychainSealKeySource(service: service, account: "seal-v1")
        let first: Data
        do {
            first = try source.key32()
        } catch StateStoreError.sealing(let message) where message.contains("-34018") {
            throw XCTSkip("keychain unavailable in this (unsigned) simulator: \(message)")
        }
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(try source.key32(), first, "second read returns the stored key, not a new one")
        let sealer = try ChaChaPolySealer(keySource: source)
        XCTAssertEqual(try sealer.open(try sealer.seal(Data("state".utf8))), Data("state".utf8))
    }

    func testLiveStorageFallsBackWithoutAppGroup() throws {
        var config = AppModel.Dependencies.LiveConfiguration()
        config.appGroup = "group.invalid.familychat.tests"
        let directory = try AppModel.Dependencies.storageDirectory(config)
        XCTAssertEqual(directory.lastPathComponent, "FamilyChat")
        XCTAssertTrue(directory.path.contains("Application Support"), directory.path)
    }
}
