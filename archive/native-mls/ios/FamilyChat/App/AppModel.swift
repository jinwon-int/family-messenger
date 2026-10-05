// 앱 상태기계 (#271 §5·§9). 의존성은 전부 FamilyMLSCore 프로토콜 — 테스트는 가짜 엔진·InMemory 스토어로 돈다.
//
//   starting → needsLogin → needsEnrollment → ready ⇄ halted(reason)
//                                                ↘ fatal(reason)
//
// 규칙(설계 승계):
//  - 지문 외에는 키를 화면·로그에 내지 않는다.
//  - ⛔ 정지는 무음으로 넘기지 않는다: 사유를 들고 `halted` 로 가고, 재시작 뒤에도 유지(`MessageStore.rooms().haltedReason`).
//  - 로그아웃은 자격증명·푸시 토큰만 지우고 MLS 상태는 지우지 않는다("이 기기 지우기"는 별도, 새 기기가 됨).
import Foundation
import FamilyMLSCore

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case needsLogin
        case needsEnrollment
        case ready
        case halted(String)
        case fatal(String)
    }

    struct Dependencies {
        var engineFactory: MlsEngineFactory
        var stateStore: MlsStateStore
        var messageStore: MessageStore
        var outbox: OutboxStore
        var cursors: CursorStore
        var identityProvider: () -> DeviceID
        var expectedDecryptFormat: () -> UInt32
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var deviceId: DeviceID = ""
    @Published private(set) var fingerprint: String = ""
    @Published private(set) var credential: RelayCredential?
    @Published private(set) var rooms: [RoomRecord] = []
    @Published private(set) var lastError: String?

    private let deps: Dependencies
    private(set) var engine: MlsEngine?

    init(dependencies: Dependencies) { self.deps = dependencies }

    // MARK: - 수명주기

    func bootstrap() async {
        guard phase == .starting else { return }
        guard deps.expectedDecryptFormat() == Framing.decryptFormat else {
            phase = .fatal(Strings.decryptFormatMismatch); return
        }
        do {
            let id = deps.identityProvider()
            // 뼈대: 영속 상태가 있으면 복원, 없으면 새 신원. (L1 파일 스토어가 들어오면 그대로 동작)
            let engine: MlsEngine = try deps.stateStore.withExclusive(room: Strings.identityRoom, timeout: 2) { tx in
                if let bytes = try tx.load() {
                    return try deps.engineFactory.importState(identity: id, bytes: bytes)
                }
                let fresh = try deps.engineFactory.create(identity: id)
                try tx.save(try fresh.exportState())
                return fresh
            }
            self.engine = engine
            deviceId = id
            fingerprint = try engine.fingerprint()
            rooms = try deps.messageStore.rooms()
            phase = credential == nil ? .needsLogin : .needsEnrollment
        } catch {
            phase = .fatal("\(error)")
        }
    }

    func login(_ credential: RelayCredential) {
        self.credential = credential
        if phase == .needsLogin { phase = .needsEnrollment }
    }

    /// 릴레이가 이 기기를 수락(403 device_subject_mismatch 해소)했을 때 L3 동기화가 호출한다. 뼈대에서는 화면 버튼.
    func markEnrolled() {
        guard phase == .needsEnrollment else { return }
        phase = haltedReasonFromRooms().map { .halted($0) } ?? .ready
    }

    func halt(reason: String, room: RoomID? = nil) {
        if let room { try? deps.messageStore.setHalted(room: room, reason: reason) }
        phase = .halted(reason)
    }

    func logout() {
        credential = nil
        phase = .needsLogin
    }

    // MARK: - 화면용 읽기

    /// 화면이 엔진의 공개 정보(공개키)만 읽는 좁은 창. 키 자체는 노출하지 않는다.
    func engineForUI() -> MlsEngine? { engine }

    func messages(room: RoomID) -> [MessageRecord] {
        (try? deps.messageStore.messages(room: room, after: 0, limit: 500)) ?? []
    }

    func refreshRooms() {
        rooms = (try? deps.messageStore.rooms()) ?? []
    }

    // MARK: - 뼈대 송신: 암호화 → outbox(정확 바이트). 네트워크는 L3 동기화 엔진이 outbox 를 비운다.

    func send(room: RoomID, text: String) {
        guard let engine, case .ready = phase else { return }
        let clientId = "\(deviceId):\(UUID().uuidString.prefix(8))"
        do {
            let bytes = try deps.stateStore.withExclusive(room: room, timeout: 2) { tx -> Data in
                let input = Framing.encryptInput(room: room, clientId: clientId, plaintext: Data(text.utf8))
                let ciphertext = try engine.dispatch(.encrypt, input)
                try tx.save(try engine.exportState())
                return ciphertext
            }
            try deps.outbox.enqueue(OutboxEntry(room: room, clientId: clientId, kind: "application", epoch: 0, bytes: bytes, status: .pending, createdAt: Date()))
            lastError = nil
        } catch EngineError.rejected(let reason) {
            lastError = Strings.sendRejected(reason)
        } catch {
            lastError = "\(error)"
        }
    }

    private func haltedReasonFromRooms() -> String? {
        rooms.compactMap(\.haltedReason).first
    }
}

extension AppModel.Dependencies {
    /// 실제 엔진(xcframework) + InMemory 스토어. L1 머지 후 `stateStore`/`messageStore`/`outbox`/`cursors` 를 파일 구현으로 교체.
    static func live() -> Self {
        Self(
            engineFactory: FfiEngineFactory(),
            stateStore: InMemoryStateStore(),
            messageStore: InMemoryMessageStore(),
            outbox: InMemoryOutboxStore(),
            cursors: InMemoryCursorStore(),
            identityProvider: { DeviceIdentity.stableDeviceId(actor: "owner") },
            expectedDecryptFormat: { FfiEngineFactory.reportedDecryptFormat() }
        )
    }
}
