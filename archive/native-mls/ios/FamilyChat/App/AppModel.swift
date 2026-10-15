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
        /// 첫 실행: 이 기기 사용자 이름(actor)을 고르기 전. 기기 ID `<actor>-iphone-<hex>` 가 여기서 정해진다(가족 투입).
        case needsActor
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
        /// 로그인 시트(§12-C A, AppLogin.swift)가 여는 릴레이 기본 주소. nil = 미설정(그때는 makeTransport 도 nil 을 준다).
        var relayURL: URL? = nil
        /// 푸시 등록(§12-D, 결정 D6). 기본 = topic 없음(등록 안 함) — live() 가 Info.plist 로 채운다.
        var push = PushRegistrar.Dependencies(topic: nil)
        var syncConfiguration = RoomSyncEngine.Configuration()
        /// 저장소를 열지 못했다(App Group·Keychain 등) — bootstrap 이 곧바로 fatal 로 간다.
        var startupFailure: String?
        /// 릴레이 자격증명 영속(Keychain, NSE 와 공유 — 결정 D8). 기본 = 메모리(테스트).
        var credentials: CredentialStoring = InMemoryCredentialStore()
        /// 이 기기 사용자 이름(actor). nil = 첫 실행이라 아직 고르지 않음 → `.needsActor`. 기본 = 이미 고름("owner", 테스트).
        var actorStore: ActorStoring = InMemoryActorStore("owner")
        /// 참여 요청 화면이 미리 채우는 대화방 ID(빌드 설정 `FC_DEFAULT_ROOM` → Info.plist `FamilyChatDefaultRoom`).
        var defaultRoom: RoomID = "family-acc"
        /// "이 기기 지우기"(§9-5) 훅. 기본 = 아무것도 지우지 않음(테스트는 주입, live() 는 파일·DB·기기 ID 로 채운다).
        var wipe = DeviceWipe()
    }

    /// 저장소 밖의 삭제 작업(§9-5). `storage` = MLS 상태 전부(identity 슬롯 포함) + messages.db 행, `identity` = 저장된 기기 ID.
    struct DeviceWipe {
        var storage: () throws -> Void = {}
        var identity: () -> Void = {}
    }

    @Published private(set) var phase: Phase = .starting
    /// 로그인 시트가 여는 릴레이 주소(빌드 설정 FC_RELAY_URL). nil 이면 로그인 화면이 버튼 대신 안내를 보인다.
    var relayURL: URL? { deps.relayURL }
    @Published private(set) var deviceId: DeviceID = ""
    @Published private(set) var fingerprint: String = ""
    /// 바뀔 때마다 저장소에 반영한다(로그인 = 저장, 로그아웃·401 = 삭제) — NSE 가 같은 세션으로 릴레이를 읽는다.
    @Published private(set) var credential: RelayCredential? {
        didSet {
            guard credential != oldValue else { return }
            if let credential { try? deps.credentials.save(credential) } else { deps.credentials.delete() }
        }
    }
    @Published private(set) var rooms: [RoomRecord] = []
    @Published private(set) var lastError: String?
    /// 등록 대기 화면이 보여 줄 JSON 의 원본(운영자 CLI 입력).
    @Published private(set) var registration: EnrollmentRequest?
    /// 메시지가 새로 저장될 때마다 오른다 — 방 화면이 다시 읽는 신호.
    @Published private(set) var messagesRevision = 0
    /// 설정 화면의 알림 상태(D6).
    @Published private(set) var pushStatus: PushRegistrar.Status = .off
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
    private var unconfirmed: [String: PendingOwn] = [:]

    /// 서버 확인 전 내 메시지(텍스트 또는 첨부 바이트 + 추정 MIME).
    struct PendingOwn {
        let room: RoomID
        let kind: MessageRecord.Kind
        let body: String
        let attachment: Data?
    }
    /// 방별 마지막으로 본 영속 커서 — NSE 가 사이에 처리했는지 감지(전면 복귀 시 화면 갱신).
    private var seenCursors: [RoomID: Int64] = [:]
    private let serial = SerialAsyncQueue()
    let push: PushRegistrar

    init(dependencies: Dependencies) {
        self.deps = dependencies
        self.push = PushRegistrar(dependencies.push)
    }

    // MARK: - 수명주기

    func bootstrap() async {
        guard phase == .starting else { return }
        if let failure = deps.startupFailure { phase = .fatal(failure); return }
        guard deps.expectedDecryptFormat() == Framing.decryptFormat else {
            phase = .fatal(Strings.decryptFormatMismatch); return
        }
        // 기기 ID 를 만들기 전에 actor 가 정해져 있어야 한다(기존 설치는 저장된 ID 에서 actor 를 읽으므로 이 화면을 보지 않는다).
        guard deps.actorStore.actor != nil else { phase = .needsActor; return }
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
            // 지난 실행의 세션(Keychain)으로 이어 간다 — 만료됐으면 첫 동기화의 401 이 로그인 화면으로 보낸다.
            if credential == nil, let saved = deps.credentials.load() { login(saved) }
            phase = credential == nil ? .needsLogin : .needsEnrollment
        } catch {
            phase = .fatal("\(error)")
        }
    }

    /// 첫 실행의 사용자 이름 선택. 형식이 틀리면 false(화면이 안내), 맞으면 저장 후 시작을 이어 간다. 한 설치에서 한 번뿐이다.
    @discardableResult
    func chooseActor(_ raw: String) async -> Bool {
        guard phase == .needsActor else { return false }
        let actor = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ActorName.isValid(actor) else { lastError = Strings.actorInvalid; return false }
        deps.actorStore.save(actor)
        lastError = nil
        phase = .starting
        await bootstrap()
        return true
    }

    func login(_ credential: RelayCredential) {
        guard let transport = deps.makeTransport(credential) else {
            lastError = Strings.relayNotConfigured; return
        }
        self.credential = credential
        self.transport = transport
        syncEngines = [:]   // 새 전송으로 다시 만든다(커서·정지 사유는 저장소에 있다). 등록 subject 도 새 자격증명으로 다시 읽는다.
        refreshRegistrationSubject()
        push.loggedIn()
        lastError = nil
        if phase == .needsLogin { phase = .needsEnrollment }
    }

    /// 등록 JSON 의 `subject` = 자격증명 JWT 의 `sub`(DEVICES-V4 §필드 필수, relay-app `enroll-info` 와 같은 규칙).
    /// 서비스 토큰처럼 `sub` 가 없으면 비워 두고 운영자가 채운다. 릴레이는 등록 subject ≠ 실제 `sub` 면 403 으로 거부하므로
    /// 여기서 읽은 값이 권한을 만들지는 않는다.
    private func refreshRegistrationSubject() {
        guard let engine else { return }
        let subject = credential?.accessSubject ?? ""
        guard registration?.subject != subject, let updated = try? EnrollmentRequest(engine: engine, subject: subject) else { return }
        registration = updated
    }

    /// 자격증명만 지운다. 푸시 등록은 릴레이에서 지운다(DELETE, 최선) — 다음 로그인의 등록과 섞이지 않게 같은 `serial` 에 줄 세운다.
    @discardableResult
    func logout() -> Task<Void, Never> {
        let device = deviceId
        let previous = transport
        credential = nil
        transport = nil
        syncEngines = [:]
        phase = .needsLogin
        pushStatus = .off
        return Task {
            try? await self.serial.run { await self.push.unregister(device: device, transport: previous) }
            self.pushStatus = self.push.status
        }
    }

    func halt(reason: String, room: RoomID? = nil) {
        if let room { try? deps.messageStore.setHalted(room: room, reason: reason) }
        phase = .halted(reason)
    }

    /// "이 기기 지우기"(§9-5): 로그아웃과 달리 **MLS 상태(서명키 포함)·대화 기록·기기 ID 를 모두 지우고 새 기기가 된다.**
    /// 순서(모두 `serial` 안, 동기화와 겹치지 않게): ① 푸시 등록 해제(DELETE 최선) → ② 사용자 이름(actor)을 명시 저장(기기 ID 에서
    /// 파생하던 설치도 이름을 잃지 않게) → ③ 세션·메모리 상태 폐기 → ④ 저장소 삭제(`wipe.storage`: MLS 상태 전부 + DB 행)
    /// → ⑤ 기기 ID 삭제(`wipe.identity`) → ⑥ `bootstrap` 다시(새 ID·새 서명키·새 지문 → `needsLogin`).
    /// 릴레이 쪽(정책 체인의 옛 기기·방 멤버십)은 지우지 않는다 — 운영자가 `-revoke` 하고 새 기기를 등록한다. 봉인 키(Keychain)는
    /// 유지한다: 이 프로세스의 저장소 인스턴스가 키를 들고 있어 바꾸면 NSE 와 어긋난다(키는 파일 보호용이지 대화 비밀이 아니다).
    func wipeDevice() async throws {
        switch phase { case .starting, .fatal: return; default: break }
        let device = deviceId
        let previous = transport
        try await serial.run {
            await self.push.unregister(device: device, transport: previous)
            self.pushStatus = self.push.status
            if let actor = self.deps.actorStore.actor { self.deps.actorStore.save(actor) }
            self.credential = nil
            self.transport = nil
            self.syncEngines = [:]; self.unconfirmed = [:]; self.seenCursors = [:]; self.lastFlush = [:]
            self.engine = nil; self.identitySeed = nil; self.registration = nil; self.rooms = []
            try self.deps.wipe.storage()
            self.deps.wipe.identity()
            self.deviceId = ""; self.fingerprint = ""
            self.lastError = nil
            self.phase = .starting
            await self.bootstrap()
        }
    }

    // MARK: - ⛔ 정지 해제 (§9-4 "정지 이유" + 다음 행동)

    enum RejoinOutcome: Equatable {
        /// 상태를 지우고 키 패키지까지 올렸다 — 재초대를 기다린다.
        case prepared
        /// 상태는 지웠지만 참여 요청(키 패키지 게시)은 실패했다(연결 없음·세션 만료) — `+ 참여 요청` 으로 다시 올릴 수 있다.
        case preparedWithoutPublish(String)
    }

    enum RejoinError: Error, Equatable {
        /// 이 저장소는 방 상태 삭제를 지원하지 않는다(`RoomStateRemoving` 미채택).
        case unsupported
        case notHalted
    }

    /// 정지된 방 목록(화면용). `rooms` 와 같은 순서.
    var haltedRooms: [RoomRecord] { rooms.filter { $0.haltedReason != nil } }

    /// 정지 해제 = 이 기기의 **방 상태를 버리고** 재초대를 기다린다(relay-app·봇과 같은 길: RELAY-APP.md §정지). 거부된 commit 을
    /// 받아들이는 경로는 없다. 순서(모두 `serial` 안):
    ///   ① 방 동기화 객체 폐기 → ② MLS 방 상태 삭제(방 flock 안, `RoomStateRemoving`) → ③ 커서 0·epoch/revision 0·정지 사유 nil
    ///   → ④ 그 방의 pending outbox 는 reconciled(옛 epoch 바이트는 영영 못 들어간다) → ⑤ 가능하면 키 패키지 게시(= 참여 요청).
    /// 메시지 행(`messages`)은 지우지 않는다 — 지난 대화는 화면에 남고, 재참여 뒤 새 seq 만 이어진다.
    func prepareRejoin(room: RoomID) async throws -> RejoinOutcome {
        guard room != Strings.identityRoom else { throw RejoinError.unsupported }
        guard let remover = deps.stateStore as? RoomStateRemoving else { throw RejoinError.unsupported }
        guard (try deps.messageStore.rooms().first { $0.room == room })?.haltedReason != nil else { throw RejoinError.notHalted }
        return try await serial.run {
            self.syncEngines[room] = nil
            self.seenCursors[room] = nil
            try remover.removeState(room: room, timeout: self.deps.syncConfiguration.lockTimeout)
            for entry in try self.deps.outbox.pending(room: room) {
                try self.deps.outbox.mark(room: room, clientId: entry.clientId, status: .reconciled)
            }
            try self.deps.cursors.setCursor(room: room, seq: 0)
            var record = try self.deps.messageStore.rooms().first { $0.room == room }
                ?? RoomRecord(room: room, epoch: 0, revision: 0, haltedReason: nil, displayOrder: 0)
            record.epoch = 0; record.revision = 0; record.haltedReason = nil
            try self.deps.messageStore.upsertRoom(record)
            try self.deps.messageStore.setHalted(room: room, reason: nil)
            self.rooms = try self.deps.messageStore.rooms()
            if case .halted = self.phase { self.phase = self.haltedReasonFromRooms().map { .halted($0) } ?? .ready }
            do {
                guard self.transport != nil else { throw RelayError.unauthorized }
                try await self.membership(room).publishKeyPackage()
                return .prepared
            } catch {
                return .preparedWithoutPublish("\(error)")
            }
        }
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
        switch phase { case .starting, .needsActor, .needsLogin, .fatal: return; default: break }
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
                // 커서가 움직였으면(이 프로세스든 NSE 든 새로 처리·기록했다) 화면이 다시 읽는다.
                let cursor = try deps.cursors.cursor(room: record.room)
                if passes.contains(where: { !$0.inserted.isEmpty || !$0.rejected.isEmpty }) || seenCursors[record.room] != cursor {
                    messagesRevision += 1
                }
                seenCursors[record.room] = cursor
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
                try await syncPushLocked(transport)
            }
            lastError = nil
        } catch RelayError.unauthorized {
            expireSession()
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - 푸시 (§12-D)

    /// `didRegisterForRemoteNotificationsWithDeviceToken` — 등록된 기기면 곧바로 릴레이에 올린다(아니면 ready 때).
    func pushTokenReceived(_ token: Data) async {
        push.tokenReceived(token)
        try? await serial.run {
            guard let transport = self.transport, self.isEnrolledPhase else { return }
            do { try await self.syncPushLocked(transport) } catch RelayError.unauthorized { self.expireSession() }
        }
        pushStatus = push.status
    }

    func pushTokenFailed(_ reason: String) {
        push.tokenFailed(reason)
        pushStatus = push.status
    }

    /// 앱이 전면일 때 온 푸시(D7): 시스템 알림은 억제했고 여기서 바로 동기화해 화면에 보인다.
    /// NSE 가 먼저 복호화했으면 동기화로는 새 행이 안 생기므로(커서가 이미 지났다) 화면 갱신 신호를 직접 올린다.
    func receivedWhileActive() async {
        await refresh()
        refreshRooms()
        messagesRevision += 1
    }

    private var isEnrolledPhase: Bool {
        switch phase { case .ready, .halted: return true; default: return false }
    }

    private func syncPushLocked(_ transport: RelayTransport) async throws {
        push.activate()
        try await push.syncIfNeeded(device: deviceId, transport: transport)
        pushStatus = push.status
    }

    private func expireSession() {
        credential = nil; transport = nil; syncEngines = [:]
        phase = .needsLogin
        lastError = Strings.sessionExpired
    }

    // MARK: - 방 참여·만들기·초대 (§12-E: JoinRequestView · CreateRoomView · InviteView)

    /// 참여 요청·방 만들기·초대 버튼을 보일지: 등록이 끝나 `ready` 이고 전송이 있을 때만(정지·등록 대기 중에는 무의미하다).
    var canRequestJoin: Bool {
        if case .ready = phase { return transport != nil }
        return false
    }

    /// 참여 요청 화면이 미리 채우는 대화방 ID.
    var defaultRoom: RoomID { deps.defaultRoom }

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
        await sendOwn(room: room, pending: PendingOwn(room: room, kind: .text, body: text, attachment: nil)) {
            try await $0.send(text: text)
        }
    }

    /// 첨부(≤256 KiB, 원본 바이트 그대로 — AttachmentFormat). 한도 초과는 암호화 전에 `lastError` 로 거절한다.
    @discardableResult
    func sendAttachment(room: RoomID, data: Data) async -> SendOutcome? {
        guard data.count <= AttachmentFormat.maxBytes else { lastError = Strings.attachmentTooLarge(data.count); return nil }
        let pending = PendingOwn(room: room, kind: .attachment, body: AttachmentFormat.sniffMime(data), attachment: data)
        return await sendOwn(room: room, pending: pending) { try await $0.send(attachment: data) }
    }

    private func sendOwn(room: RoomID, pending: PendingOwn, _ operation: @escaping (RoomSyncEngine) async throws -> SendOutcome) async -> SendOutcome? {
        guard case .ready = phase else { return nil }
        do {
            let outcome = try await serial.run { try await operation(try self.syncEngine(room)) }
            switch outcome {
            case .sent(let clientId, let seq, _):
                unconfirmed[clientId] = pending
                try recordOwn(clientId: clientId, seq: seq)
                lastError = nil
            case .queued(let clientId):
                unconfirmed[clientId] = pending
                lastError = Strings.sendQueued
            case .reconciled:
                lastError = nil
            }
            return outcome
        } catch SyncError.attachmentTooLarge(let size) {
            lastError = Strings.attachmentTooLarge(size)
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

    /// 화면 쪽 오류(첨부 읽기 실패 등)를 같은 자리(`lastError`)에 보인다.
    func noteError(_ message: String) { lastError = message }

    /// 화면이 엔진의 공개 정보(공개키)만 읽는 좁은 창. 키 자체는 노출하지 않는다.
    func engineForUI() -> MlsEngine? { engine }

    /// 타임라인 1행: 첨부 본체는 빼고(`record.attachment == nil`) 크기만. 본체는 `attachment(room:seq:)` 로 화면이 보일 때 읽는다(#364).
    struct TimelineItem: Equatable, Identifiable {
        let record: MessageRecord
        let attachmentBytes: Int
        var id: Int64 { record.seq }
    }

    func messages(room: RoomID) -> [TimelineItem] {
        if let loading = deps.messageStore as? AttachmentLoading,
           let heads = try? loading.messageHeads(room: room, after: 0, limit: 500) {
            return heads.map { TimelineItem(record: $0.record, attachmentBytes: $0.attachmentBytes) }
        }
        // 지연 로딩을 모르는 저장소: 종전처럼 BLOB 포함으로 읽고 크기만 떼어 둔다.
        return ((try? deps.messageStore.messages(room: room, after: 0, limit: 500)) ?? []).map { r in
            TimelineItem(record: MessageRecord(room: r.room, seq: r.seq, senderDevice: r.senderDevice, clientId: r.clientId, kind: r.kind,
                                               body: r.body, attachment: nil, receivedAt: r.receivedAt, decryptedBy: r.decryptedBy),
                         attachmentBytes: r.attachment?.count ?? 0)
        }
    }

    /// 첨부 본체(≤ `AttachmentFormat.maxBytes`). 말풍선이 보일 때 한 번 읽는다.
    func attachment(room: RoomID, seq: Int64) -> Data? {
        if let loading = deps.messageStore as? AttachmentLoading { return try? loading.attachment(room: room, seq: seq) }
        return (try? deps.messageStore.messages(room: room, after: seq - 1, limit: 1))?.first { $0.seq == seq }?.attachment
    }

    func refreshRooms() {
        rooms = (try? deps.messageStore.rooms()) ?? []
    }

    /// 등록 JSON(운영자 CLI 입력). subject 는 로그인한 자격증명 JWT 의 `sub`(`refreshRegistrationSubject`) — 없으면 빈값, 운영자가 채운다.
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
                                                       kind: pending.kind, body: pending.body, attachment: pending.attachment,
                                                       receivedAt: Date(), decryptedBy: .app))
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
