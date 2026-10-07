// §12-D 수용 ④ — 푸시 등록 요청 형식·멱등·토큰 교체·DELETE(가짜 전송). 결정 D6·D7(NOTES-FINALIZER.md).
// 와이어 바이트(JSON 키·base64·경로·메서드)는 Core RelayTransportTests 가 server push.go 와 대조해 고정한다.
import XCTest
import UserNotifications
import FamilyMLSCore
@testable import FamilyChat

/// 등록·해제 호출을 기록하는 메모리 릴레이. `registerFailures` 개수만큼 먼저 실패한다.
final class RecordingPushRelay: InMemoryRelayWrapper {
    var registrations: [PushRegistration] = []
    var unregistrations: [DeviceID] = []
    var registerFailures: [Error] = []
    var refuseListing: Error?

    override func listRooms(device: DeviceID) async throws -> RoomsResponse {
        if let refuseListing { throw refuseListing }
        return try await super.listRooms(device: device)
    }

    override func registerPush(_ registration: PushRegistration) async throws {
        if !registerFailures.isEmpty { throw registerFailures.removeFirst() }
        registrations.append(registration)
    }

    override func unregisterPush(device: DeviceID) async throws {
        unregistrations.append(device)
    }
}

final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
final class PushRegistrationTests: XCTestCase {
    private let device = "owner-iphone-abc123"
    private let topic = "com.example.familychat.ios"
    private let token = Data((0..<32).map { UInt8($0) })

    private var relay: RecordingPushRelay!
    private var clock: TestClock!
    private var records: InMemoryPushRecordStore!
    private var tokenRequests = 0
    private var denial: String?

    override func setUp() async throws {
        relay = RecordingPushRelay()
        clock = TestClock()
        records = InMemoryPushRecordStore()
        tokenRequests = 0
        denial = nil
    }

    private func makeModel(topic: String?) -> AppModel {
        var push = PushRegistrar.Dependencies(topic: topic)
        push.records = records
        push.now = { [clock] in clock!.now }
        push.requestToken = { [weak self] onDenied in
            guard let self else { return }
            self.tokenRequests += 1
            if let denial = self.denial { onDenied(denial) }
        }
        let deps = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: InMemoryStateStore(), messageStore: InMemoryMessageStore(),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { [device] in device }, expectedDecryptFormat: { 2 },
            makeTransport: { [relay] _ in relay }, push: push)
        return AppModel(dependencies: deps)
    }

    private func readyModel(topic: String? = "com.example.familychat.ios") async -> AppModel {
        let model = makeModel(topic: topic)
        await model.bootstrap()
        model.login(.bearer("jwt"))
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        return model
    }

    /// ready 진입 → 토큰 요청 1회 → 토큰 → POST {device, token, topic} 1회. 같은 토큰·다음 폴링은 다시 보내지 않는다(멱등).
    func testReadyDeviceRegistersTokenOnceAndStaysIdempotent() async {
        let model = await readyModel()
        XCTAssertEqual(tokenRequests, 1)
        XCTAssertEqual(model.pushStatus, .waitingForToken)
        XCTAssertEqual(relay.registrations, [])

        await model.pushTokenReceived(token)
        XCTAssertEqual(relay.registrations, [PushRegistration(device: device, apnsToken: token, topic: topic)])
        XCTAssertEqual(model.pushStatus, .registered(clock.now))
        XCTAssertEqual(records.load()?.token, token)

        await model.refresh()
        await model.refresh()
        await model.pushTokenReceived(token)
        XCTAssertEqual(relay.registrations.count, 1, "같은 (device, token, topic) 은 다시 보내지 않는다")
        XCTAssertEqual(tokenRequests, 1, "토큰 요청은 실행당 한 번")
    }

    /// 토큰 교체(시스템 재발급) → 새 토큰으로 다시 POST(서버 upsert).
    func testRotatedTokenRegistersAgain() async {
        let model = await readyModel()
        await model.pushTokenReceived(token)
        let rotated = Data(repeating: 0xee, count: 32)
        await model.pushTokenReceived(rotated)
        XCTAssertEqual(relay.registrations.map(\.apnsToken), [token, rotated])
        XCTAssertEqual(records.load()?.token, rotated)
    }

    /// 지난 등록이 같아도 24시간이 지나면 한 번 다시 올린다(릴레이가 Apple 410 으로 토큰을 지웠을 수 있다).
    func testDailyRefreshReRegistersSameToken() async {
        records.save(PushRegistrationRecord(device: device, token: token, topic: topic, registeredAt: clock.now))
        let model = makeModel(topic: topic)
        await model.bootstrap()
        model.login(.bearer("jwt"))
        await model.pushTokenReceived(token)            // 로그인 뒤 첫 회 = 강제 1회
        XCTAssertEqual(relay.registrations.count, 0, "등록 확인(ready) 전에는 보내지 않는다")
        await model.refresh()
        XCTAssertEqual(relay.registrations.count, 1, "로그인 뒤 첫 동기화는 기록이 같아도 다시 보낸다")
        clock.advance(3600)
        await model.refresh()
        XCTAssertEqual(relay.registrations.count, 1)
        clock.advance(24 * 3600)
        await model.refresh()
        XCTAssertEqual(relay.registrations.count, 2, "24시간 뒤 재등록")
    }

    /// 미등록 기기(403 device_subject_mismatch): 권한도 묻지 않고 토큰이 와도 보내지 않는다.
    func testUnenrolledDeviceNeitherAsksNorRegisters() async {
        relay.refuseListing = RelayError.refused(code: RelayErrorCode.deviceSubjectMismatch.rawValue, status: 403)
        let model = makeModel(topic: topic)
        await model.bootstrap()
        model.login(.bearer("jwt"))
        await model.refresh()
        XCTAssertEqual(model.phase, .needsEnrollment)
        await model.pushTokenReceived(token)
        XCTAssertEqual(tokenRequests, 0)
        XCTAssertEqual(relay.registrations, [])
        // 운영자가 등록하면 다음 폴링에서 ready → 권한 요청 → (이미 받은 토큰으로) 등록
        relay.refuseListing = nil
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(tokenRequests, 1)
        XCTAssertEqual(relay.registrations.count, 1)
    }

    /// 로그아웃 = DELETE ?device + 로컬 기록 삭제. 다시 로그인하면 다시 등록한다.
    func testLogoutUnregistersAndReloginRegistersAgain() async {
        let model = await readyModel()
        await model.pushTokenReceived(token)
        await model.logout().value
        XCTAssertEqual(relay.unregistrations, [device])
        XCTAssertNil(records.load())
        XCTAssertEqual(model.phase, .needsLogin)
        XCTAssertEqual(model.pushStatus, .off)

        model.login(.bearer("jwt2"))
        await model.refresh()
        XCTAssertEqual(relay.registrations.count, 2)
        XCTAssertEqual(relay.registrations.last, PushRegistration(device: device, apnsToken: token, topic: topic))
    }

    /// 로그아웃 DELETE 가 실패해도(오프라인) 로컬 기록은 지워진다 — 다음 로그인에서 다시 등록.
    func testLogoutWithoutTransportClearsRecord() async {
        let model = makeModel(topic: topic)
        await model.bootstrap()
        records.save(PushRegistrationRecord(device: device, token: token, topic: topic, registeredAt: clock.now))
        await model.logout().value          // 로그인 전: 전송 없음
        XCTAssertNil(records.load())
        XCTAssertEqual(relay.unregistrations, [])
    }

    /// 실패 → 지수 백오프(1분, 2분…) 동안 폴링(4초)마다 재시도하지 않는다. 시간이 지나면 같은 내용으로 다시.
    func testFailuresBackOffInsteadOfRetryingEveryPoll() async {
        relay.registerFailures = [RelayError.network("offline"), RelayError.refused(code: "internal", status: 500)]
        let model = await readyModel()
        await model.pushTokenReceived(token)
        XCTAssertEqual(model.pushStatus, .failed(Strings.pushNetwork))
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(relay.registerFailures.count, 1, "백오프 중에는 시도하지 않는다")
        clock.advance(61)
        await model.refresh()                 // 두 번째 실패(500) → 다음은 2분 뒤
        XCTAssertEqual(relay.registerFailures.count, 0)
        XCTAssertEqual(model.pushStatus, .failed("internal (500)"))
        clock.advance(61)
        await model.refresh()
        XCTAssertEqual(relay.registrations.count, 0)
        clock.advance(60)
        await model.refresh()
        XCTAssertEqual(relay.registrations, [PushRegistration(device: device, apnsToken: token, topic: topic)])
        XCTAssertEqual(model.pushStatus, .registered(clock.now))
    }

    /// 등록 중 401 = 세션 만료 — 동기화와 같이 재로그인 화면.
    func testUnauthorizedRegistrationReturnsToLogin() async {
        relay.registerFailures = [RelayError.unauthorized]
        let model = await readyModel()
        await model.pushTokenReceived(token)
        XCTAssertEqual(model.phase, .needsLogin)
        XCTAssertEqual(model.lastError, Strings.sessionExpired)
    }

    /// topic(Bundle ID) 미설정 빌드: 권한을 묻지 않고 등록하지 않으며 사유를 보인다.
    func testMissingTopicNeverRegisters() async {
        let model = await readyModel(topic: nil)
        await model.pushTokenReceived(token)
        XCTAssertEqual(tokenRequests, 0)
        XCTAssertEqual(relay.registrations, [])
        XCTAssertEqual(model.pushStatus, .unavailable(Strings.pushNoTopic))
    }

    /// 알림 권한 거부 → 토큰 요청 없음 상태로 사유를 보인다.
    func testDeniedPermissionIsSurfaced() async {
        denial = Strings.pushDenied
        let model = await readyModel()
        await model.refresh()
        XCTAssertEqual(model.pushStatus, .unavailable(Strings.pushDenied))
        XCTAssertEqual(relay.registrations, [])
    }

    /// D7: 앱이 전면(active)이면 시스템 알림을 억제하고, 아니면 배너·목록·소리.
    func testForegroundPresentationSuppressesSystemAlertWhenActive() {
        XCTAssertEqual(ForegroundPresentation.options(appActive: true), [])
        XCTAssertEqual(ForegroundPresentation.options(appActive: false), [.banner, .list, .sound])
    }

    /// 전면 수신 → 동기화 + 화면 갱신 신호(NSE 가 먼저 처리해 새 행이 없어도 화면은 다시 읽는다).
    func testReceivedWhileActiveBumpsRevision() async {
        let model = await readyModel()
        let before = model.messagesRevision
        await model.receivedWhileActive()
        XCTAssertGreaterThan(model.messagesRevision, before)
    }
}
