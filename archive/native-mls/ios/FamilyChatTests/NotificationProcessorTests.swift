// §12-D 수용 ① — 실패·타임아웃·lock 경합 경로에서 대체 알림 100% (결정 D5, NOTES-FINALIZER.md).
// 가짜 엔진·메모리 릴레이로 NSE 처리(`NotificationProcessor`)의 모든 실패 갈래를 표로 돌리고, 결과가 하나도 빠짐없이
// "새 메시지가 도착했습니다"(빈 본문·loc-key 원문 없음)인지 센다. 실 엔진 복호화 성공 경로는 CrossProcessTests.
import XCTest
import CryptoKit
import FamilyMLSCore
@testable import FamilyChat

/// 고정된 events 페이지 하나를 돌려주는 전송(서버 JSON 을 디코드 — 와이어 타입에 public init 이 없다).
final class PageTransport: InMemoryRelayWrapper {
    var page: [String: Any]
    var getError: Error?
    var getDelay: TimeInterval = 0
    init(events: [[String: Any]]) {
        page = ["epoch": 1, "revision": 1, "events": events, "next_after": (events.last?["seq"] as? Int) ?? 0, "members": []]
    }
    override func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage {
        if getDelay > 0 { try await Task.sleep(nanoseconds: UInt64(getDelay * 1_000_000_000)) }
        if let getError { throw getError }
        return try JSONDecoder().decode(EventsPage.self, from: JSONSerialization.data(withJSONObject: page))
    }
    static func application(seq: Int, from device: DeviceID, bytes: Data = Data("ct".utf8)) -> [String: Any] {
        ["seq": seq, "device": device, "client_id": "\(device)-\(seq)", "kind": "application", "epoch": 1,
         "bytes": bytes.base64EncodedString(), "sha256": "", "created_at": 0]
    }
}

struct ThrowingImportFactory: MlsEngineFactory {
    func create(identity: DeviceID) throws -> MlsEngine { throw EngineError.rejected("corrupt") }
    func importState(identity: DeviceID, bytes: Data) throws -> MlsEngine { throw EngineError.rejected("corrupt state") }
}

final class NotificationProcessorTests: XCTestCase {
    private let room: RoomID = "family"
    private let me: DeviceID = "owner-iphone-abc123"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fc-nse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let sealKey = SymmetricKey(size: .bits256)

    /// 무서명 시뮬레이터는 Keychain 이 막혀 있어 정적 키 봉인(앱 통합 테스트와 같은 방식). Linux 하네스는 Core 기본(Passthrough).
    private func fileStore() throws -> FileStateStore {
        #if os(iOS)
        return try FileStateStore(directory: dir.appendingPathComponent("mls"), sealer: ChaChaPolySealer(key: Self.sealKey))
        #else
        return try FileStateStore(directory: dir.appendingPathComponent("mls"), sealer: nil)
        #endif
    }

    private func environment(transport: RelayTransport? = PageTransport(events: [PageTransport.application(seq: 7, from: "alice-pc")]),
                             identity: DeviceID? = "owner-iphone-abc123",
                             credential: RelayCredential? = .bearer("jwt"),
                             rooms: [RoomRecord]? = nil,
                             stateStore: MlsStateStore = NotificationProcessorTests.seededStore(),
                             factory: MlsEngineFactory = FakeFactory(),
                             lockTimeout: TimeInterval = 3) -> NotificationProcessor.Environment {
        let messages = InMemoryMessageStore(seedRooms: rooms ?? [RoomRecord(room: room, epoch: 1, revision: 1, haltedReason: nil, displayOrder: 0)])
        var configuration = NotificationProcessor.defaultConfiguration
        configuration.lockTimeout = lockTimeout
        return NotificationProcessor.Environment(
            identity: { identity }, credential: { credential }, makeTransport: { _ in transport },
            engineFactory: factory, stateStore: stateStore, messages: messages,
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(), configuration: configuration)
    }

    /// identity 슬롯(D2 시드)이 있는 상태 저장소 — 앱이 bootstrap 에서 만들어 두는 것과 같다.
    static func seededStore() -> InMemoryStateStore {
        let store = InMemoryStateStore()
        try? store.withExclusive(room: Strings.identityRoom, timeout: 1) { try $0.save(Data("s0".utf8)) }
        return store
    }

    private func push(_ seq: Int64 = 7) -> [AnyHashable: Any] { ["aps": ["mutable-content": 1], "room": room, "seq": seq] }

    private func assertFallback(_ result: ProcessedNotification, _ reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.body, Strings.pushFallbackBody, "빈손/원문 키 금지", file: file, line: line)
        XCTAssertFalse(result.body.isEmpty, file: file, line: line)
        guard case .fallback(let actual) = result.outcome else {
            return XCTFail("expected fallback(\(reason)), got \(result.outcome)", file: file, line: line)
        }
        XCTAssertTrue(actual.hasPrefix(reason), "reason \(actual) ≠ \(reason)", file: file, line: line)
    }

    /// 대체 문구는 앱 번들 NEW_MESSAGE(시스템이 NSE 없이 푸는 문구)와 같다.
    func testFallbackTextMatchesTheSystemLocKeyText() throws {
        XCTAssertEqual(Strings.pushFallbackBody, "새 메시지가 도착했습니다")
        #if os(iOS)
        let resolved = Bundle(for: AppModel.self).localizedString(forKey: "NEW_MESSAGE", value: "<missing>", table: nil)
        XCTAssertEqual(resolved, Strings.pushFallbackBody, "ko.lproj/Localizable.strings 의 NEW_MESSAGE")
        #endif
    }

    func testPayloadParsing() {
        XCTAssertEqual(NotificationPayload(userInfo: ["room": "family", "seq": 42]), NotificationPayload(userInfo: ["room": "family", "seq": NSNumber(value: 42)]))
        XCTAssertEqual(NotificationPayload(userInfo: ["room": "family", "seq": Int64(9)])?.seq, 9)
        XCTAssertNil(NotificationPayload(userInfo: [:]))
        XCTAssertNil(NotificationPayload(userInfo: ["room": "family"]))
        XCTAssertNil(NotificationPayload(userInfo: ["room": "", "seq": 1]))
        XCTAssertNil(NotificationPayload(userInfo: ["room": "family", "seq": "1"]))
        XCTAssertNil(NotificationPayload(userInfo: ["room": "family", "seq": 0]))
    }

    /// 수용 ①: 모든 실패 갈래 → 대체 알림. 표의 결과를 세어 100% 를 단정한다.
    func testEveryFailurePathFallsBack() async throws {
        let halted = [RoomRecord(room: room, epoch: 1, revision: 1, haltedReason: "committer_mismatch", displayOrder: 0)]
        let network = PageTransport(events: []); network.getError = RelayError.network("offline")
        let expired = PageTransport(events: []); expired.getError = RelayError.unauthorized
        let pending = PageTransport(events: []); pending.getError = RelayError.refused(code: RelayErrorCode.deviceSubjectMismatch.rawValue, status: 403)
        let closed = PageTransport(events: []); closed.getError = RelayError.refused(code: RelayErrorCode.roomClosed.rawValue, status: 410)
        let server = PageTransport(events: []); server.getError = RelayError.refused(code: "internal", status: 500)
        let stateWithGarbage = InMemoryStateStore()
        try stateWithGarbage.withExclusive(room: room, timeout: 1) { try $0.save(Data("garbage".utf8)) }

        let cases: [(String, [AnyHashable: Any], NotificationProcessor.Environment)] = [
            ("payload", [:], environment()),
            ("payload", ["room": room], environment()),
            ("payload", ["room": room, "seq": "7"], environment()),
            ("no_identity", push(), environment(identity: nil)),
            ("no_credential", push(), environment(credential: nil)),
            ("no_relay", push(), environment(transport: nil)),
            ("unknown_room", push(), environment(rooms: [])),
            ("halted", push(), environment(rooms: halted)),
            ("network", push(), environment(transport: network)),
            ("unauthorized", push(), environment(transport: expired)),
            ("registration_pending", push(), environment(transport: pending)),
            ("halted", push(), environment(transport: closed)),
            ("error", push(), environment(transport: server)),
            ("error", push(), environment(stateStore: stateWithGarbage, factory: ThrowingImportFactory())),
            // 가짜 엔진은 그룹이 없어(members 프레임 아님) application 을 읽지 않는다 → 그 seq 의 행 없음
            ("no_message_at_seq", push(), environment()),
            ("no_message_at_seq", push(99), environment()),
        ]
        var fallbacks = 0
        for (reason, payload, env) in cases {
            let result = await NotificationProcessor(env).process(payload)
            assertFallback(result, reason)
            if result.isFallback && result.body == Strings.pushFallbackBody { fallbacks += 1 }
        }
        XCTAssertEqual(fallbacks, cases.count, "대체 알림 \(fallbacks)/\(cases.count)")
        print("[nse] fallback paths: \(fallbacks)/\(cases.count)")
    }

    /// lock 경합: 다른 프로세스(같은 디렉터리의 두 번째 FileStateStore)가 방 락을 쥔 동안 → 대기 상한 뒤 대체 알림.
    func testLockHeldByOtherProcessFallsBackAfterTimeout() async throws {
        let mine = try fileStore()
        let other = try fileStore()
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let room = self.room
        Thread.detachNewThread {
            try? other.withExclusive(room: room, timeout: 1) { _ in
                holding.signal()
                _ = release.wait(timeout: .now() + 10)
            }
        }
        XCTAssertEqual(holding.wait(timeout: .now() + 5), .success)
        let started = Date()
        let result = await NotificationProcessor(environment(stateStore: mine, lockTimeout: 0.3)).process(push())
        release.signal()
        assertFallback(result, "lock_timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "락 상한(0.3 s) 근처에서 포기")
    }

    /// 기한: 릴레이가 응답하지 않아도 기한에 대체 알림(작업은 뒤에서 계속 — 취소하지 않는다).
    func testDeadlineDeliversFallbackWhileWorkIsStuck() async {
        let slow = PageTransport(events: [PageTransport.application(seq: 7, from: "alice-pc")])
        slow.getDelay = 5
        let processor = NotificationProcessor(environment(transport: slow))
        let started = Date()
        let result = await NotificationDeadline.race(budget: 0.3) { await processor.process(self.push()) }
        assertFallback(result, "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testDeadlinePassesThroughAFastResult() async {
        let fast = ProcessedNotification(title: "alice", body: "안녕", outcome: .decrypted(seq: 3))
        let result = await NotificationDeadline.race(budget: 5) { fast }
        XCTAssertEqual(result, fast)
    }

    /// 전달은 한 번만(처리 결과·기한·serviceExtensionTimeWillExpire 중 처음 것).
    func testOnceFlagLetsExactlyOneDeliveryThrough() {
        let once = OnceFlag()
        let results = (0..<100).map { _ in once.claim() }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertTrue(results[0])
    }

    /// 저장된 행 → 알림 문구: 제목 = actor(봇 🤖), 본문 = 텍스트/「사진」/「파일」, 해독 불가 = 대체.
    func testContentMapping() {
        var env = environment()
        env.agentActors = NotificationProcessor.agentActors(from: " claude , ,hermes")
        XCTAssertEqual(env.agentActors, ["claude", "hermes"])
        let processor = NotificationProcessor(env)
        func record(_ device: DeviceID, _ kind: MessageRecord.Kind, _ body: String) -> MessageRecord {
            MessageRecord(room: room, seq: 5, senderDevice: device, clientId: "c", kind: kind, body: body, attachment: nil,
                          receivedAt: Date(), decryptedBy: .nse)
        }
        XCTAssertEqual(processor.content(for: record("alice-iphone-1a2b3c", .text, "저녁 먹자")),
                       ProcessedNotification(title: "alice", body: "저녁 먹자", outcome: .decrypted(seq: 5)))
        XCTAssertEqual(processor.content(for: record("claude-bot-01", .text, "요약입니다"))?.title, "🤖 claude")
        XCTAssertEqual(processor.content(for: record("alice-pc", .attachment, "image/jpeg"))?.body, Strings.pushPhoto)
        XCTAssertEqual(processor.content(for: record("alice-pc", .attachment, "IMG_0001.HEIC"))?.body, Strings.pushPhoto)
        XCTAssertEqual(processor.content(for: record("alice-pc", .attachment, "계약서.pdf"))?.body, Strings.pushFile)
        XCTAssertNil(processor.content(for: record("alice-pc", .undecryptable, "no key")))
    }
}
