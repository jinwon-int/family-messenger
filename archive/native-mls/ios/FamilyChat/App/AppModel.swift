// 앱 상태기계 (#271 §5·§9) + 통합(파이널라이저): L1 파일 저장소 · L3 동기화 엔진 · ios-ffi 엔진을 잇는다.
//
//   starting → needsLogin → needsEnrollment → ready ⇄ halted(reason)
//                                                ↘ fatal(reason)
//
// 규칙(설계 승계):
//  - 지문 외에는 키를 화면·로그에 내지 않는다.
//  - ⛔ 정지는 무음으로 넘기지 않는다: 사유를 들고 `halted` 로 가고, 재시작 뒤에도 유지(`MessageStore.rooms().haltedReason`).
//  - 로그아웃은 자격증명만 지우고 MLS 상태는 지우지 않는다("이 기기 지우기"는 별도, 새 기기가 됨).
//
// 상태 배치(결정 D2): `_identity` 슬롯 = 이 기기의 서명키만 든 파사드 상태(그룹·키 패키지 없음). 방마다 `<room>` 상태가
// 따로 있고, 처음 만들 때 슬롯 바이트를 import 해 시작한다(`SeededEngineFactory`) — 모든 방이 같은 서명키·지문을 쓴다.
//
// 릴레이 연산(동기화·송신·초대)은 `serial` 하나로 줄 세운다: `RoomSyncEngine` 은 방마다 단일 호출자를 전제한다.
// 등록 판정은 확장 ① `GET /v2/rooms`(403 device_subject_mismatch = 등록 대기, 401 = 재로그인)와 방 동기화의
// `registrationPending` 둘 다로 한다. 확장 ① 이 없는 릴레이(404)면 아는 방만 동기화한다.
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
        /// 자격증명 → 릴레이 전송. nil = 릴레이 주소가 설정되지 않음.
        var makeTransport: (RelayCredential) -> RelayTransport?
        var syncConfiguration = RoomSyncEngine.Configuration()
        /// 저장소를 열지 못했다(App Group·Keychain 등) — bootstrap 이 곧바로 fatal 로 간다.
        var startupFailure: String?
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var deviceId: DeviceID = ""
    @Published private(set) var fingerprint: String = ""
    @Published private(set) var credential: RelayCredential?
    @Published private(set) var rooms: [RoomRecord] = []
    @Published private(set) var lastError: String?
    /// 등록 대기 화면이 보여 줄 JSON 의 원본(운영자 CLI 입력).
    @Published private(set) var registration: EnrollmentRequest?
    /// 메시지가 새로 저장될 때마다 오른다 — 방 화면이 다시 읽는 신호.
    @Published private(set) var messagesRevision = 0
    /// 마지막 refresh 의 outbox 재전송 결과(정확 바이트 재시도 관찰용 — 화면·테스트).
    private(set) var lastFlush: [RoomID: [SendOutcome]] = [:]

    private let deps: Dependencies
    private(set) var engine: MlsEngine?
    private var identitySeed: Data?
    private var transport: RelayTransport?
    private var syncEngines: [RoomID: RoomSyncEngine] = [:]
    /// 아직 서버 확인(seq)을 못 받은 내 메시지의 평문(clientId → 본문). MLS 는 자기 메시지를 복호화하지 못하므로
    /// 내 메시지는 서버가 seq 를 준 순간 여기서 MessageStore 에 쓴다. 앱이 그 전에 끝나면 평문은 사라지고
    /// (바이트는 outbox 에 남아 같은 바이트로 나간다) 내 화면에만 안 보인다 — 상대는 정상 수신.
    private var unconfirmed: [String: (room: RoomID, text: String)] = [:]
    private let serial = SerialAsyncQueue()

    init(dependencies: Dependencies) { self.deps = dependencies }

    // MARK: - 수명주기

    func bootstrap() async {
        guard phase == .starting else { return }
        if let failure = deps.startupFailure { phase = .fatal(failure); return }
        guard deps.expectedDecryptFormat() == Framing.decryptFormat else {
            phase = .fatal(Strings.decryptFormatMismatch); return
        }
        do {
            let id = deps.identityProvider()
            // identity 슬롯: 있으면 복원, 없으면 새 신원을 만들어 즉시 저장(서명키가 흔들리지 않게).
            let (engine, seed): (MlsEngine, Data) = try deps.stateStore.withExclusive(room: Strings.identityRoom, timeout: 2) { tx in
                if let bytes = try tx.load() {
                    return (try deps.engineFactory.importState(identity: id, bytes: bytes), bytes)
                }
                let fresh = try deps.engineFactory.create(identity: id)
                let bytes = try fresh.exportState()
                try tx.save(bytes)
                return (fresh, bytes)
            }
            self.engine = engine
            identitySeed = seed
            deviceId = id
            fingerprint = try engine.fingerprint()
            registration = try EnrollmentRequest(engine: engine, subject: "")
            rooms = try deps.messageStore.rooms()
            phase = credential == nil ? .needsLogin : .needsEnrollment
        } catch {
            phase = .fatal("\(error)")
        }
    }

    func login(_ credential: RelayCredential) {
        guard let transport = deps.makeTransport(credential) else {
            lastError = Strings.relayNotConfigured; return
        }
        self.credential = credential
        self.transport = transport
        syncEngines = [:]   // 새 전송으로 다시 만든다(커서·정지 사유는 저장소에 있다)
        lastError = nil
        if phase == .needsLogin { phase = .needsEnrollment }
    }

    func logout() {
        credential = nil
        transport = nil
        syncEngines = [:]
        phase = .needsLogin
    }

    func halt(reason: String, room: RoomID? = nil) {
        if let room { try? deps.messageStore.setHalted(room: room, reason: reason) }
        phase = .halted(reason)
    }

    /// 포그라운드 폴링(CONTRACTS §2.2: 4초). 화면의 `.task` 가 소유하고 취소하면 끝난다.
    func runForeground() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: UInt64(deps.syncConfiguration.pollInterval * 1_000_000_000))
        }
    }

    // MARK: - 동기화

    /// 한 바퀴: 등록 확인·방 목록(확장 ①) → 방마다 syncAll → 정지 아니면 outbox 재전송(같은 바이트).
    func refresh() async {
        try? await serial.run { await self.refreshLocked() }
    }

    private func refreshLocked() async {
        guard let transport, engine != nil else { return }
        switch phase { case .starting, .needsLogin, .fatal: return; default: break }
        do {
            do {
                let listing = try await transport.listRooms(device: deviceId)
                for room in listing.rooms where !room.closed && (room.member || room.keypackagesOutstanding > 0) {
                    try ensureRoomRecord(room.room)
                }
            } catch RelayError.refused(let code, let status) where status == 403 && code == RelayErrorCode.deviceSubjectMismatch.rawValue {
                phase = .needsEnrollment
                return
            } catch RelayError.refused(_, let status) where status == 404 {
                // 확장 ① 이 없는 릴레이 — 아는 방만 동기화한다.
            }
            var pending = false
            lastFlush = [:]
            for record in try deps.messageStore.rooms() {
                let sync = try syncEngine(record.room)
                let passes = try await sync.syncAll()
                if passes.contains(where: { !$0.inserted.isEmpty || !$0.rejected.isEmpty }) { messagesRevision += 1 }
                if sync.registrationPending != nil { pending = true; continue }
                if sync.haltedReason == nil {
                    let outcomes = try await sync.flushOutbox()
                    lastFlush[record.room] = outcomes
                    for case .sent(let clientId, let seq, _) in outcomes { try recordOwn(clientId: clientId, seq: seq) }
                }
            }
            rooms = try deps.messageStore.rooms()
            if pending {
                phase = .needsEnrollment
            } else {
                phase = haltedReasonFromRooms().map { .halted($0) } ?? .ready
            }
            lastError = nil
        } catch RelayError.unauthorized {
            credential = nil; self.transport = nil; syncEngines = [:]
            phase = .needsLogin
            lastError = Strings.sessionExpired
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - 방 참여·만들기·초대 (화면은 §12-E — 여기서는 동작만)

    /// 이 방에 키 패키지를 게시한다(상대가 초대할 수 있게). 방 목록에 바로 나타난다.
    func requestJoin(room: RoomID) async throws {
        try await serial.run {
            try await self.membership(room).publishKeyPackage()
            try self.ensureRoomRecord(room)
            self.rooms = try self.deps.messageStore.rooms()
        }
    }

    /// 로컬 그룹을 만든다. 릴레이의 방은 첫 초대 commit 이 만든다.
    func createRoom(room: RoomID) async throws {
        try await serial.run {
            try self.membership(room).createGroup()
            try self.ensureRoomRecord(room)
            self.rooms = try self.deps.messageStore.rooms()
        }
    }

    func invite(room: RoomID, target: DeviceID) async throws {
        try await serial.run {
            try await self.membership(room).invite(target: target, sync: try self.syncEngine(room))
        }
    }

    // MARK: - 송신

    /// 동기화 → encrypt → outbox(정확 바이트) → POST. 409 는 엔진이 1회 재암호화, 네트워크 실패는 pending 으로 남는다.
    @discardableResult
    func send(room: RoomID, text: String) async -> SendOutcome? {
        guard case .ready = phase else { return nil }
        do {
            let outcome = try await serial.run { try await self.syncEngine(room).send(text: text) }
            switch outcome {
            case .sent(let clientId, let seq, _):
                unconfirmed[clientId] = (room, text)
                try recordOwn(clientId: clientId, seq: seq)
                lastError = nil
            case .queued(let clientId):
                unconfirmed[clientId] = (room, text)
                lastError = Strings.sendQueued
            case .reconciled:
                lastError = nil
            }
            return outcome
        } catch SyncError.halted(let reason) {
            halt(reason: reason, room: room)
        } catch SyncError.registrationPending {
            phase = .needsEnrollment
        } catch SyncError.notJoined {
            lastError = Strings.notJoined
        } catch EngineError.rejected(let reason) {
            lastError = Strings.sendRejected(reason)
        } catch {
            lastError = "\(error)"
        }
        return nil
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

    /// 등록 JSON(운영자 CLI 입력). subject 는 CF Access `sub` — 앱이 모르면 비워 두고 운영자가 채운다.
    func registrationJSON() -> String {
        (try? registration?.json()) ?? ""
    }

    // MARK: - 내부

    private var roomEngineFactory: MlsEngineFactory {
        SeededEngineFactory(base: deps.engineFactory) { [identitySeed] in
            guard let identitySeed else { throw StateStoreError.io("identity slot not loaded") }
            return identitySeed
        }
    }

    private func syncEngine(_ room: RoomID) throws -> RoomSyncEngine {
        if let existing = syncEngines[room] { return existing }
        guard let transport else { throw RelayError.unauthorized }
        let sync = try RoomSyncEngine(room: room, identity: deviceId, engineFactory: roomEngineFactory, stateStore: deps.stateStore,
                                      outbox: deps.outbox, cursors: deps.cursors, messages: deps.messageStore, transport: transport,
                                      configuration: deps.syncConfiguration, enrollmentSubject: registration?.subject ?? "")
        syncEngines[room] = sync
        return sync
    }

    private func membership(_ room: RoomID) throws -> RoomMembership {
        guard let transport else { throw RelayError.unauthorized }
        return RoomMembership(room: room, identity: deviceId, engineFactory: roomEngineFactory, stateStore: deps.stateStore,
                              transport: transport, lockTimeout: deps.syncConfiguration.lockTimeout)
    }

    private func ensureRoomRecord(_ room: RoomID) throws {
        let existing = try deps.messageStore.rooms()
        guard !existing.contains(where: { $0.room == room }) else { return }
        try deps.messageStore.upsertRoom(RoomRecord(room: room, epoch: 0, revision: 0, haltedReason: nil,
                                                    displayOrder: (existing.map(\.displayOrder).max() ?? -1) + 1))
    }

    /// 서버가 seq 를 준 내 메시지를 기록한다(이미 있으면 건너뜀 — 같은 seq 를 두 번 쓰지 않는다).
    private func recordOwn(clientId: String, seq: Int64) throws {
        guard let pending = unconfirmed.removeValue(forKey: clientId) else { return }
        if try deps.messageStore.messages(room: pending.room, after: seq - 1, limit: 1).first?.seq != seq {
            try deps.messageStore.insert(MessageRecord(room: pending.room, seq: seq, senderDevice: deviceId, clientId: clientId,
                                                       kind: .text, body: pending.text, attachment: nil, receivedAt: Date(), decryptedBy: .app))
        }
        messagesRevision += 1
    }

    private func haltedReasonFromRooms() -> String? {
        rooms.compactMap(\.haltedReason).first
    }
}

/// 비동기 연산을 들어온 순서대로 하나씩 실행한다(메인 액터 위의 단일 호출자 보장).
@MainActor
final class SerialAsyncQueue {
    private var tail: Task<Void, Never>?

    func run<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
