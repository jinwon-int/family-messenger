// §12-D 수용 ②③ — 실 ios-ffi 엔진으로 App 과 NSE 가 같은 기기 저장소를 함께 쓴다(결정 D4, NOTES-FINALIZER.md).
//
//   "두 프로세스" = 같은 디렉터리를 연 서로 다른 저장소 인스턴스: App 은 AppModel(live 조립)의 FileStateStore·FileSQLiteStore,
//   NSE 는 NotificationProcessor 가 새로 연 FileStateStore·FileSQLiteStore(flock 은 열린 파일마다 따로라 프로세스 간과 같은 경합).
//   복호화 횟수는 양쪽 엔진 팩토리를 감싼 계수기로 센다 — 같은 암호문을 두 번 푸는 시도 자체가 0 이어야 한다(MLS 는 재복호화 불가).
//
// ② testAppAndNSEConcurrentlyNeverCorruptOrDoubleDecrypt: 라운드마다 alice 송신 → bob 의 App refresh ∥ NSE 푸시 처리(동시)
// ③ testNSEPathDecryptsWithTheRealEngine: NSE 경로 복호화 성공(제목 actor·본문 평문·decryptedBy nse) → App 은 다시 풀지 않음
import CryptoKit
import XCTest
import FamilyMLSCore
@testable import FamilyChat

/// 복호화 시도·성공을 암호문(decrypt 입력)별로 센다. App·NSE 가 서로 다른 스레드에서 함께 쓴다.
final class DecryptCounter {
    private let lock = NSLock()
    private var attempts: [Data: Int] = [:]
    private var successes: [Data: Int] = [:]

    func record(_ input: Data, success: Bool) {
        lock.lock(); defer { lock.unlock() }
        attempts[input, default: 0] += 1
        if success { successes[input, default: 0] += 1 }
    }
    var totalSuccesses: Int { lock.lock(); defer { lock.unlock() }; return successes.values.reduce(0, +) }
    var maxAttemptsPerCiphertext: Int { lock.lock(); defer { lock.unlock() }; return attempts.values.max() ?? 0 }
    var totalAttempts: Int { lock.lock(); defer { lock.unlock() }; return attempts.values.reduce(0, +) }
}

final class CountingEngine: MlsEngine {
    let base: MlsEngine
    let counter: DecryptCounter
    init(base: MlsEngine, counter: DecryptCounter) { self.base = base; self.counter = counter }
    var identity: DeviceID { base.identity }
    func dispatch(_ method: EngineMethod, _ input: Data) throws -> Data {
        guard method == .decrypt else { return try base.dispatch(method, input) }
        do {
            let output = try base.dispatch(method, input)
            counter.record(input, success: true)
            return output
        } catch {
            counter.record(input, success: false)
            throw error
        }
    }
    func exportState() throws -> Data { try base.exportState() }
    func publicKey() throws -> Data { try base.publicKey() }
    func fingerprint() throws -> String { try base.fingerprint() }
    func hasPending() throws -> Bool { try base.hasPending() }
}

struct CountingEngineFactory: MlsEngineFactory {
    let base: MlsEngineFactory
    let counter: DecryptCounter
    func create(identity: DeviceID) throws -> MlsEngine { CountingEngine(base: try base.create(identity: identity), counter: counter) }
    func importState(identity: DeviceID, bytes: Data) throws -> MlsEngine {
        CountingEngine(base: try base.importState(identity: identity, bytes: bytes), counter: counter)
    }
}

extension ScenarioDevice {
    /// 이 기기의 NSE: 같은 디렉터리를 **새 인스턴스**로 연다(App 과 다른 fd·다른 SQLite 연결 = 다른 프로세스 대역).
    func nseEnvironment(transport: RelayTransport, engineFactory: MlsEngineFactory,
                        agentActors: Set<String> = []) throws -> NotificationProcessor.Environment {
        var sealer: FileStateSealing?
        #if os(iOS)
        sealer = ChaChaPolySealer(key: sealKey)   // App 과 같은 봉인 키(운영에선 공유 Keychain 그룹)
        #endif
        let state = try FileStateStore(directory: directory.appendingPathComponent("mls", isDirectory: true), sealer: sealer)
        let db = try FileSQLiteStore(directory: directory)
        let id = self.id
        return NotificationProcessor.Environment(
            identity: { id }, credential: { .bearer("smoke") }, makeTransport: { _ in transport },
            engineFactory: engineFactory, stateStore: state, messages: db, outbox: db, cursors: db,
            agentActors: agentActors)
    }

    func records(_ room: RoomID) -> [MessageRecord] { model.messages(room: room) }
}

struct SendFailed: Error {}

@MainActor
final class CrossProcessTests: XCTestCase {
    private var root: URL!
    private let room: RoomID = "family"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fc-xp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// alice·bob 로그인 → bob 키 패키지 → alice 방·초대 → bob 참여(TwoDeviceScenario ①② 와 같은 순서).
    private func joinedPair(relay: InMemoryRelay, counter: DecryptCounter) async throws -> (alice: ScenarioDevice, bob: ScenarioDevice) {
        let alice = ScenarioDevice(id: "alice-iphone-a1a1a1", base: relay, root: root)
        let bob = ScenarioDevice(id: "bob-iphone-b2b2b2", base: relay, root: root,
                                 wrapFactory: { CountingEngineFactory(base: $0, counter: counter) })
        for device in [alice, bob] {
            await device.model.bootstrap()
            device.model.login(.bearer("smoke"))
            await device.model.refresh()
        }
        try await bob.model.requestJoin(room: room)
        try await alice.model.createRoom(room: room)
        try await alice.model.invite(room: room, target: bob.id)
        await bob.model.refresh()
        XCTAssertEqual(bob.model.phase, .ready, "bob joined (\(bob.model.lastError ?? "-"))")
        return (alice, bob)
    }

    private func send(_ device: ScenarioDevice, _ text: String) async throws -> Int64 {
        guard case .sent(_, let seq, _)? = await device.model.send(room: room, text: text) else {
            XCTFail("send failed: \(device.model.lastError ?? "-")")
            throw SendFailed()
        }
        return seq
    }

    /// ③ NSE 경로: 실 엔진으로 복호화 → 알림 = (actor, 평문), 행은 decryptedBy nse. 그 뒤 App 은 같은 암호문을 다시 풀지 않는다.
    func testNSEPathDecryptsWithTheRealEngine() async throws {
        let relay = InMemoryRelay()
        let counter = DecryptCounter()
        let (alice, bob) = try await joinedPair(relay: relay, counter: counter)
        let seq = try await send(alice, "NSE 로 푼 메시지")

        let nse = NotificationProcessor(try bob.nseEnvironment(transport: relay,
                                                               engineFactory: CountingEngineFactory(base: FfiEngineFactory(), counter: counter)))
        let result = await nse.process(["aps": ["mutable-content": 1, "alert": ["loc-key": "NEW_MESSAGE"]], "room": room, "seq": seq])
        XCTAssertEqual(result, ProcessedNotification(title: "alice", body: "NSE 로 푼 메시지", outcome: .decrypted(seq: seq)))
        XCTAssertEqual(counter.totalSuccesses, 1)

        await bob.model.refresh()
        XCTAssertEqual(bob.texts(room), ["NSE 로 푼 메시지"], "App 화면은 NSE 가 기록한 행을 읽는다")
        XCTAssertEqual(bob.records(room).map(\.decryptedBy), [.nse])
        XCTAssertEqual(counter.totalAttempts, 1, "App 은 같은 메시지를 다시 복호화하지 않는다")

        // 봇 actor 는 🤖, App 이 먼저 처리한 seq 도 NSE 는 (복호화 없이) 같은 내용을 보인다.
        let second = try await send(alice, "두 번째")
        await bob.model.refresh()
        let bot = NotificationProcessor(try bob.nseEnvironment(transport: relay, engineFactory: CountingEngineFactory(base: FfiEngineFactory(), counter: counter),
                                                               agentActors: ["alice"]))
        let again = await bot.process(["room": room, "seq": second])
        XCTAssertEqual(again, ProcessedNotification(title: "🤖 alice", body: "두 번째", outcome: .decrypted(seq: second)))
        XCTAssertEqual(counter.totalAttempts, 2)
        print("[nse] real-engine NSE decrypt PASS (seq \(seq)), app re-decrypts 0")
    }

    /// 해독 불가(위조 암호문) → NSE 는 대체 알림, 행은 undecryptable 하나, 뒤 메시지는 정상(상태 손상 없음).
    func testUndecryptableMessageFallsBackWithoutBreakingTheRoom() async throws {
        let relay = InMemoryRelay()
        let counter = DecryptCounter()
        let (alice, bob) = try await joinedPair(relay: relay, counter: counter)
        _ = try await send(alice, "정상 1")
        await bob.model.refresh()
        let epoch = try await relay.getEvents(room: room, device: alice.id, after: 0, limit: 1, ack: nil).epoch
        let forged = try await relay.postEvent(room: room, EventPost(device: alice.id, clientId: "forged-1", kind: .application,
                                                                     epoch: epoch, bytes: Data("not an mls message".utf8)))
        let nse = NotificationProcessor(try bob.nseEnvironment(transport: relay, engineFactory: CountingEngineFactory(base: FfiEngineFactory(), counter: counter)))
        let result = await nse.process(["room": room, "seq": forged.seq])
        XCTAssertEqual(result.body, Strings.pushFallbackBody)
        XCTAssertEqual(result.outcome, .fallback("undecryptable"))
        let after = try await send(alice, "정상 2")
        let next = await nse.process(["room": room, "seq": after])
        XCTAssertEqual(next.body, "정상 2")
        await bob.model.refresh()
        XCTAssertEqual(bob.texts(room), ["정상 1", "정상 2"])
        XCTAssertEqual(bob.records(room).filter { $0.kind == .undecryptable }.map(\.seq), [forged.seq])
    }

    /// ② App ∥ NSE 동시 처리 반복: 상태 손상 0·중복 복호화 0·모든 알림에 본문.
    func testAppAndNSEConcurrentlyNeverCorruptOrDoubleDecrypt() async throws {
        let relay = InMemoryRelay()
        let counter = DecryptCounter()
        let (alice, bob) = try await joinedPair(relay: relay, counter: counter)
        let nse = NotificationProcessor(try bob.nseEnvironment(transport: relay,
                                                               engineFactory: CountingEngineFactory(base: FfiEngineFactory(), counter: counter)))
        let rounds = 30
        var expected: [String] = []
        var decryptedByNSE = 0, fallbacks: [String] = []
        for round in 0..<rounds {
            var last: Int64 = 0
            for text in ["r\(round)-a", "r\(round)-b"] {
                last = try await send(alice, text)
                expected.append(text)
            }
            let room = self.room
            // 푸시 도착(NSE, 백그라운드 스레드) 과 App 전면 폴링을 동시에.
            let pushed = Task.detached { await nse.process(["room": room, "seq": last]) }
            await bob.model.refresh()
            let result = await pushed.value
            XCTAssertFalse(result.body.isEmpty, "round \(round): 빈손 알림")
            switch result.outcome {
            case .decrypted(let seq):
                XCTAssertEqual(seq, last)
                XCTAssertEqual(result.body, "r\(round)-b")
                decryptedByNSE += 1
            case .fallback(let reason):
                XCTAssertEqual(result.body, Strings.pushFallbackBody)
                fallbacks.append(reason)
            }
        }
        await bob.model.refresh()
        let records = bob.records(room)
        XCTAssertEqual(records.filter { $0.kind == .text }.map(\.body), expected, "모든 메시지가 순서대로 정확히 한 번")
        XCTAssertEqual(records.filter { $0.kind == .undecryptable }.count, 0)
        XCTAssertEqual(counter.totalSuccesses, expected.count, "복호화 성공 = 메시지 수")
        XCTAssertEqual(counter.maxAttemptsPerCiphertext, 1, "같은 암호문 복호화 시도는 한 번뿐(중복 복호화 0)")

        // 상태 손상 0: 마지막에 App 경로·NSE 경로 둘 다 새 메시지를 푼다.
        let tailApp = try await send(alice, "끝-App")
        await bob.model.refresh()
        XCTAssertEqual(bob.records(room).last?.seq, tailApp)
        XCTAssertEqual(bob.texts(room).last, "끝-App")
        let tailNSE = try await send(alice, "끝-NSE")
        let final = await nse.process(["room": room, "seq": tailNSE])
        XCTAssertEqual(final.body, "끝-NSE")
        let byApp = records.filter { $0.decryptedBy == .app }.count
        print("[xproc] rounds=\(rounds) messages=\(expected.count) app_decrypted=\(byApp) nse_decrypted=\(records.count - byApp)"
              + " nse_notifications_with_body=\(decryptedByNSE) nse_fallbacks=\(fallbacks.count) \(Set(fallbacks).sorted())"
              + " decrypt_attempts=\(counter.totalAttempts) max_per_ciphertext=\(counter.maxAttemptsPerCiphertext)")
    }
}
