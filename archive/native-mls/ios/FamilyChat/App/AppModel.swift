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
//
// 로비 key package(#380 P5-3, `LobbyKeyring`): `_lobby` 슬롯에 방 무관 key package 를 두고 릴레이 로비에 게시해 두면
// steward 봇이 어느 방에서든 소비해 초대한다(사람 기기 탭 0). 한 바퀴(`refreshLocked`)의 순서:
//   방 목록 → 아는 방 동기화(방별 key package 로 만든 Welcome 은 여기서 join) → `GET /v2/lobby/welcomes` 로 **아직 참여하지
//   않은** 방을 찾아 (오너 actor = 결정 D1 A) 방 상태를 `_lobby` 로 바꾸고 커서를 Welcome 앞으로 되감아 바로 동기화(join) /
//   (가족 actor = B) `pendingInvites` 에 두고 1탭 수락을 기다린다 → 로그인·전면 복귀·참여 뒤에는 로비 보충(`replenish`).
// 로비가 없는 릴레이(404)는 조용히 건너뛴다. 로비 오류는 메시지 동기화를 막지 않는다(`lastError` 에만).
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
        /// 기본은 사람 가족 방 `family` — 에이전트 방 `family-acc` 를 기본으로 두면 가족 기기가 거기에 게시한다(#383).
        var defaultRoom: RoomID = "family"
        /// "이 기기 지우기"(§9-5) 훅. 기본 = 아무것도 지우지 않음(테스트는 주입, live() 는 파일·DB·기기 ID 로 채운다).
        var wipe = DeviceWipe()
        /// 로비 key package 목표 수(#380, 오너 결정 D2 = 릴레이 상한 8 과 같게). 0 = 로비를 쓰지 않는다.
        var lobbyTarget = 8
        /// 로비 Welcome 을 묻지 않고 자동 가입하는 actor(오너 결정 D1 A). 그 밖의 actor 는 1탭 수락(B).
        var autoJoinActors: Set<String> = ["owner"]
        /// 누가 에이전트인가(#405 P1 — 에이전트 카드·승인 버튼·생각 중). 빌드 설정 `FC_AGENT_ACTORS` 가 정본.
        var agentRoster = AgentRoster(actors: ["bot"])
    }

    /// 저장소 밖의 삭제 작업(§9-5). `storage` = MLS 상태 전부(identity 슬롯 포함) + messages.db 행, `identity` = 저장된 기기 ID.
    struct DeviceWipe {
        var storage: () throws -> Void = {}
        var identity: () -> Void = {}
    }

    @Published private(set) var phase: Phase = .starting
    /// #414: 첫 동기화 한 바퀴가 끝났는가. 시작 직후의 `.needsEnrollment` 는 "등록 확인 중" 자리라
    /// (저장된 세션으로 이어 갈 때 bootstrap 이 먼저 둔다) 화면은 그동안 오프닝을 보이고, 이 값이 서면 실제 상태를 보인다.
    @Published private(set) var settled = false
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
    /// 릴레이에 닿지 않는 중(네트워크 끊김·게이트웨이 502~504) — 방 화면 제목 아래 「연결 중입니다…」(오너 요청, build 29).
    /// 원문 오류(NSURLErrorDomain …)는 화면에 띄우지 않는다. 동기화·송신이 한 번 성공하면 내려간다.
    @Published private(set) var reconnecting = false
    /// 배너를 눌러 열어 달라는 방(`NotificationCenterDelegate`). `RootView` 가 방 목록이 준비되면 열고 지운다.
    @Published private(set) var requestedRoom: RoomID?
    /// 방별 보내는 글(오래된 순). 릴레이가 받으면(`recordOwn`) 빠지고 실제 기록이 그 자리를 잇는다.
    @Published private(set) var outgoing: [RoomID: [OutgoingMessage]] = [:]
    private var nextOutgoingId: Int64 = -1_000
    /// 등록 대기 화면이 보여 줄 JSON 의 원본(운영자 CLI 입력).
    @Published private(set) var registration: EnrollmentRequest?
    /// 메시지가 새로 저장될 때마다 오른다 — 방 목록이 다시 읽는 신호(어느 방이든).
    @Published private(set) var messagesRevision = 0
    /// #497: 방별 신호 — 열린 방 화면은 **자기 방**이 바뀔 때만 다시 읽고 스크롤한다. 전역 신호를 쓰던 때는 다른 방(에이전트 방 등)의
    /// 새 글에도 이 방이 다시 읽히고 최하단으로 끌려 내려갔다.
    @Published private(set) var roomRevisions: [RoomID: Int] = [:]

    func roomRevision(_ room: RoomID) -> Int { roomRevisions[room] ?? 0 }

    /// 그 방이 바뀌었다 — 방별 신호와 전역 신호를 함께 올린다.
    private func bumpRevision(_ room: RoomID) {
        roomRevisions[room, default: 0] += 1
        messagesRevision += 1
    }
    /// 설정 화면의 알림 상태(D6).
    @Published private(set) var pushStatus: PushRegistrar.Status = .off
    /// 마지막 refresh 의 outbox 재전송 결과(정확 바이트 재시도 관찰용 — 화면·테스트).
    private(set) var lastFlush: [RoomID: [SendOutcome]] = [:]
    /// 가족 기기(D1 B)의 수락 대기 초대 — 로비 Welcome 이 있는, 아직 참여하지 않은 방(오래된 순).
    @Published private(set) var pendingInvites: [PendingWelcome] = []
    /// 로비 초대로 새 방에 들어왔을 때의 한 줄 안내(화면이 `clearNotice` 로 지운다).
    @Published private(set) var notice: String?
    /// 설정 화면: 릴레이에 있는 이 기기의 미소비 로비 키 수. nil = 아직 모름(로그인 전·로비 없는 릴레이).
    @Published private(set) var lobbyLive: Int?
    /// 다음 바퀴에 로비 보충을 할지 — 로그인·전면 복귀·새 방 참여 뒤 true(4초 폴링마다 status 를 묻지 않는다).
    private var lobbyCheckDue = true
    /// 릴레이가 로비 라우트를 모른다(404) — 이 세션에서는 다시 묻지 않는다.
    private var lobbyUnsupported = false
    /// 같은 Welcome(방 → seq)을 두 번 받아들이지 않는다(상태를 바꿔도 join 하지 못한 경우 — 로비 키로 만든 Welcome 이 아니다).
    private var adoptFailed: [RoomID: Int64] = [:]
    /// 「무시」한 초대 — 이 세션에서만. Welcome 은 릴레이에 남으므로 다음 실행에 다시 보인다.
    private var dismissedInvites: Set<RoomID> = []

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

    /// 보내는 글의 상태(오너 요청 build 31): 누르는 즉시 목록에 올리고 결과는 말풍선 아래에 표시한다.
    enum OutgoingState: Equatable {
        /// 릴레이 응답 대기.
        case sending
        /// 릴레이에 닿지 않아 outbox 에 보관 — 연결되면 같은 바이트로 자동 재전송(`flushOutbox`).
        case queued
        /// 보내지 못했다(참여 전·거부·첨부 한도 등). 사용자가 「다시 보내기」로 재시도한다.
        case failed(String)
    }

    /// 아직 릴레이가 받아 주지 않은 내 글. `id` 는 음수(실제 seq 와 겹치지 않고, 화면의 표지 id -1/-2 보다 작다).
    struct OutgoingMessage: Equatable, Identifiable {
        let id: Int64
        let room: RoomID
        let kind: MessageRecord.Kind
        let body: String
        let attachment: Data?
        let createdAt: Date
        var clientId: String?
        var state: OutgoingState
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
        lobbyCheckDue = true; lobbyUnsupported = false; adoptFailed = [:]
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
            // #389: 옛 서명키로 만든 로비 키를 먼저 거둔다 — 남겨 두면 초대한 쪽은 "초대됨"인데 새 신원은 그 Welcome 을 열 수 없다(TTL 30일).
            // 최선 노력: 오프라인·세션 만료·로비 없는 릴레이(404)여도 리셋은 계속한다(남은 키는 TTL 로 사라진다).
            if let previous, !device.isEmpty { _ = try? await previous.deleteLobbyKeyPackages(device: device) }
            await self.push.unregister(device: device, transport: previous)
            self.pushStatus = self.push.status
            if let actor = self.deps.actorStore.actor { self.deps.actorStore.save(actor) }
            self.credential = nil
            self.transport = nil
            self.syncEngines = [:]; self.unconfirmed = [:]; self.seenCursors = [:]; self.lastFlush = [:]
            self.pendingInvites = []; self.notice = nil; self.lobbyLive = nil; self.adoptFailed = [:]; self.dismissedInvites = []
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
        guard room != Strings.identityRoom, room != LobbyKeyring.slot else { throw RejoinError.unsupported }
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

    // MARK: - 「목록에서 지우기」(#389)

    enum ForgetError: Error, Equatable {
        /// 저장소가 방 상태(`RoomStateRemoving`)나 방 기록(`RoomForgetting`) 삭제를 지원하지 않는다.
        case unsupported
        /// 내보내졌거나 닫힌 방만 지운다 — 다른 정지는 '다시 참여 준비'로 돌아갈 수 있다.
        case notForgettable
    }

    /// 목록에서 지울 수 있는 정지 사유: 이 기기가 그 방에 스스로 돌아갈 길이 없다(내보내짐·닫힘).
    nonisolated static func canForget(reason: String?) -> Bool {
        reason == SyncHaltReason.removedFromRoom || reason == SyncHaltReason.roomClosed
    }

    /// 대화 목록에 보일 방. 가족 기기(D1 B)가 아직 수락하지 않은 로비 초대 방은 「새 대화방 초대」 칸에만 둔다 —
    /// 봇의 commit 이 이 기기를 로스터에 넣는 순간 `GET /v2/rooms` 가 그 방을 돌려주므로(#388 리스크) 기록은 이미 있다.
    var listedRooms: [RoomRecord] {
        let invited = Set(pendingInvites.map(\.room))
        return rooms.filter { !invited.contains($0.room) }
    }

    /// 내보내졌거나 닫힌 방을 이 기기에서 잊는다(모두 `serial` 안): 동기화 객체 폐기 → MLS 방 상태 삭제 → pending outbox reconciled
    /// → 커서 0 → 방 행·메시지 행 삭제. 릴레이는 건드리지 않는다 — 내보내진 기기는 목록에 `member=false`, 닫힌 방은 `closed=true` 로
    /// 나와 `refreshLocked` 가 다시 만들지 않는다. 다시 초대받으면(새 Welcome) 방은 처음부터 다시 생긴다.
    func forgetRoom(room: RoomID) async throws {
        guard room != Strings.identityRoom, room != LobbyKeyring.slot else { throw ForgetError.notForgettable }
        guard let remover = deps.stateStore as? RoomStateRemoving,
              let forgetting = deps.messageStore as? RoomForgetting else { throw ForgetError.unsupported }
        guard Self.canForget(reason: try deps.messageStore.rooms().first { $0.room == room }?.haltedReason) else {
            throw ForgetError.notForgettable
        }
        try await serial.run {
            self.syncEngines[room] = nil
            self.seenCursors[room] = nil
            self.lastFlush[room] = nil
            self.unconfirmed = self.unconfirmed.filter { $0.value.room != room }
            try remover.removeState(room: room, timeout: self.deps.syncConfiguration.lockTimeout)
            for entry in try self.deps.outbox.pending(room: room) {
                try self.deps.outbox.mark(room: room, clientId: entry.clientId, status: .reconciled)
            }
            try self.deps.cursors.setCursor(room: room, seq: 0)
            try forgetting.forgetRoom(room)
            self.rooms = try self.deps.messageStore.rooms()
            if case .halted = self.phase { self.phase = self.haltedReasonFromRooms().map { .halted($0) } ?? .ready }
            self.bumpRevision(room)
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
        if !reconnecting { await resendUnsent() }
    }

    private func refreshLocked() async {
        guard let transport, engine != nil else { return }
        switch phase { case .starting, .needsActor, .needsLogin, .fatal: return; default: break }
        defer { settled = true }
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
                    bumpRevision(record.room)
                }
                seenCursors[record.room] = cursor
                if sync.registrationPending != nil { pending = true; continue }
                if sync.haltedReason == nil {
                    let outcomes = try await sync.flushOutbox()
                    lastFlush[record.room] = outcomes
                    for case .sent(let clientId, let seq, _) in outcomes { try recordOwn(clientId: clientId, seq: seq) }
                    for case .reconciled(let clientId) in outcomes { reopenReconciled(clientId: clientId) }
                }
            }
            rooms = try deps.messageStore.rooms()
            reconnecting = false
            if pending {
                phase = .needsEnrollment
                lastError = nil
            } else {
                phase = haltedReasonFromRooms().map { .halted($0) } ?? .ready
                try await syncPushLocked(transport)
                lastError = nil
                // 로비(#380): 아직 참여하지 않은 방의 Welcome → (A) 바로 참여 / (B) 수락 대기, 그 뒤 보충. 실패는 lastError 에만.
                try await discoverLobbyWelcomesLocked(transport)
                if lobbyCheckDue { try await replenishLobbyLocked() }
                rooms = try deps.messageStore.rooms()
                phase = haltedReasonFromRooms().map { .halted($0) } ?? .ready
            }
        } catch RelayError.unauthorized {
            expireSession()
        } catch {
            noteFailure(error)
        }
    }

    /// 동기화·송신·로비에서 잡힌 오류 하나를 화면 상태로 옮긴다(`ConnectionIssue`): 취소는 무시, 닿지 않음은
    /// 「연결 중입니다…」, 그 밖의 오류만 `lastError`.
    private func noteFailure(_ error: Error) {
        switch ConnectionIssue.classify(error, taskCancelled: Task.isCancelled) {
        case .cancelled: return
        case .unreachable: reconnecting = true
        case .other: lastError = "\(error)"
        }
    }

    // MARK: - 로비 key package (#380 P5-3)

    /// 이 기기 actor 가 자동 가입 대상인가(오너 결정 D1 A). 기기 ID 의 actor 가 우선, 없으면 저장된 actor.
    var autoJoinsLobbyInvites: Bool {
        guard let actor = ActorName.of(deviceId: deviceId) ?? deps.actorStore.actor else { return false }
        return deps.autoJoinActors.contains(actor)
    }

    private func lobbyKeyring() -> LobbyKeyring? {
        guard let transport, deps.lobbyTarget > 0, !lobbyUnsupported else { return nil }
        return LobbyKeyring(identity: deviceId, engineFactory: roomEngineFactory, stateStore: deps.stateStore, transport: transport,
                            lockTimeout: deps.syncConfiguration.lockTimeout, makeRef: RoomMembership.sha256Hex)
    }

    /// `GET /v2/lobby/welcomes` — 이 기기를 대상으로 한 Welcome 이 있고 아직 ack 하지 않은 방. 방 동기화 **뒤**에 부른다:
    /// 방별 key package 로 만든 Welcome 은 그 방 상태가 열 수 있어 보통의 동기화가 이미 join 했다. 그래도 참여하지 않은 방만
    /// 로비 상태로 바꾼다(`adoptLobbyWelcomeLocked`). 404 = 로비 없는 릴레이(건너뜀), 403 device_not_allowed = 등록 전(다음에).
    private func discoverLobbyWelcomesLocked(_ transport: RelayTransport) async throws {
        guard let keyring = lobbyKeyring() else { return }
        let welcomes: [PendingWelcome]
        do {
            welcomes = try await transport.lobbyWelcomes(device: deviceId)
        } catch RelayError.refused(_, let status) where status == 404 {
            lobbyUnsupported = true; return
        } catch RelayError.refused(let code, _) where code == RelayErrorCode.deviceNotAllowed.rawValue {
            return
        } catch RelayError.unauthorized {
            throw RelayError.unauthorized
        } catch {
            noteFailure(error); return
        }
        var invites: [PendingWelcome] = []
        for welcome in welcomes where adoptFailed[welcome.room] != welcome.seq {
            if (try? keyring.isMember(room: welcome.room)) == true { continue }   // 참여 끝 — 다음 ack 가 목록에서 지운다
            if autoJoinsLobbyInvites {
                await adoptLobbyWelcomeLocked(welcome, keyring: keyring)
            } else if !dismissedInvites.contains(welcome.room), !invites.contains(where: { $0.room == welcome.room }) {
                invites.append(welcome)
            }
        }
        pendingInvites = invites
    }

    /// 방 상태 = `_lobby` 슬롯 상태 → 커서를 Welcome 앞으로 → 그 방만 바로 동기화(join). 참여하면 안내하고 보충을 예약한다.
    /// join 하지 못하면(로비 키로 만든 Welcome 이 아님·poison) 같은 seq 는 다시 시도하지 않는다.
    private func adoptLobbyWelcomeLocked(_ welcome: PendingWelcome, keyring: LobbyKeyring) async {
        do {
            guard try keyring.adoptRoom(welcome.room) else { adoptFailed[welcome.room] = welcome.seq; return }
            syncEngines[welcome.room] = nil
            seenCursors[welcome.room] = nil
            if try deps.cursors.cursor(room: welcome.room) >= welcome.seq {
                try deps.cursors.setCursor(room: welcome.room, seq: welcome.seq - 1)
            }
            try ensureRoomRecord(welcome.room)
            let sync = try syncEngine(welcome.room)
            try await sync.syncAll()
            seenCursors[welcome.room] = try deps.cursors.cursor(room: welcome.room)
            bumpRevision(welcome.room)
            if sync.joined {
                notice = Strings.lobbyJoined(welcome.room)
                lobbyCheckDue = true   // key package 하나가 쓰였다 — 보충
            } else {
                adoptFailed[welcome.room] = welcome.seq
            }
        } catch RelayError.unauthorized {
            expireSession()
        } catch {
            adoptFailed[welcome.room] = welcome.seq
            noteFailure(error)
        }
    }

    /// `_lobby` 보충(`LobbyKeyring.replenish`). 404 = 로비 없음(이 세션에서 다시 묻지 않음), 403 device_not_allowed = 등록 전(다음에).
    private func replenishLobbyLocked() async throws {
        guard let keyring = lobbyKeyring() else { return }
        do {
            let report = try await keyring.replenish(target: deps.lobbyTarget)
            lobbyLive = report.live
            lobbyCheckDue = false
        } catch RelayError.refused(_, let status) where status == 404 {
            lobbyUnsupported = true
        } catch RelayError.refused(let code, _) where code == RelayErrorCode.deviceNotAllowed.rawValue {
            // 정책 체인에 아직 없는 기기 — 등록되면 다음 바퀴가 올린다.
        } catch RelayError.unauthorized {
            throw RelayError.unauthorized
        } catch {
            noteFailure(error)
        }
    }

    /// 앱이 전면으로 돌아왔다(scenePhase active) — 다음 바퀴에 로비 보충을 다시 본다.
    func foregrounded() async {
        lobbyCheckDue = true
        await refresh()
    }

    /// 가족 기기(B)의 「수락」: 그 방의 Welcome 을 로비 상태로 받아들여 참여한다. 실패 사유는 throw.
    func acceptInvite(room: RoomID) async throws {
        try await serial.run {
            guard let welcome = self.pendingInvites.first(where: { $0.room == room }) else { return }
            guard let keyring = self.lobbyKeyring() else { throw RelayError.unauthorized }
            await self.adoptLobbyWelcomeLocked(welcome, keyring: keyring)
            self.pendingInvites.removeAll { $0.room == room }
            self.rooms = try self.deps.messageStore.rooms()
            if let failed = self.adoptFailed[room], failed == welcome.seq { throw SyncError.notJoined }
        }
    }

    /// 「무시」: 이 세션에서는 보이지 않는다. Welcome 은 릴레이에 남아(커서 미이동) 다음 실행에 다시 묻는다.
    func dismissInvite(room: RoomID) {
        dismissedInvites.insert(room)
        pendingInvites.removeAll { $0.room == room }
    }

    func clearNotice() { notice = nil }

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
        // 방 목록만 다시 읽힌다(전역 신호). 열린 방은 `refreshLocked` 가 커서 변화(NSE 가 먼저 처리한 경우 포함)로 그 방 신호를 이미
        // 올렸다 — 여기서 방 신호까지 또 올리면 사진 한 장에 방 화면이 두 번 다시 읽히고 두 번 스크롤했다(#497).
        messagesRevision += 1
    }

    /// 배너 탭: 그 알림의 방을 열어 달라고 적어 둔다(열기는 화면 — `NotificationRoute`).
    func requestOpen(room: RoomID) { requestedRoom = room }
    func consumeRequestedRoom() { requestedRoom = nil }

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
    var agentRoster: AgentRoster { deps.agentRoster }

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
        let pending = PendingOwn(room: room, kind: .text, body: text, attachment: nil)
        return await sendOwn(room: room, pending: pending, outgoing: enqueueOutgoing(pending)) { try await $0.send(text: text) }
    }

    /// 단축어 「에이전트에게 보내기」의 결과(화면 위임 1단계 — 텍스트).
    enum ShortcutSendResult: Equatable {
        /// 릴레이가 받았다(또는 이미 받은 글로 정리됨).
        case sent
        /// 릴레이에 닿지 않아 보관 — 연결되면 같은 바이트로 다시 보낸다.
        case queued
        /// 보내지 못했다(사유는 사람이 읽는 문장).
        case failed(String)
    }

    /// 단축어(App Intent, `openAppWhenRun`)가 부르는 송신: 앱 프로세스의 **같은 모델**로만 보낸다 — 새 작성자(확장)를 만들지 않아
    /// flock·`serial`·내 글 기록(`unconfirmed`→`recordOwn`)이 화면 송신과 똑같다. 앱이 막 떠서 아직 준비 전이면 시작과 한 바퀴
    /// 동기화를 기다린다. 보낸 뒤 그 방을 열어 달라고 적는다(답이 그 방으로 온다).
    func sendFromShortcut(room: RoomID, text: String) async -> ShortcutSendResult {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .failed(Strings.shortcutEmpty) }
        await bootstrap()
        if phase != .ready { await refresh() }
        guard case .ready = phase else { return .failed(Strings.notReady) }
        guard rooms.contains(where: { $0.room == room }) else { return .failed(Strings.shortcutUnknownRoom(room)) }
        let outcome = await send(room: room, text: body)
        requestOpen(room: room)
        switch outcome {
        case .sent?, .reconciled?: return .sent
        case .queued?: return .queued
        case nil:
            switch outgoing[room]?.last?.state {
            case .queued?: return .queued
            case .failed(let reason)?: return .failed(reason)
            default: return .failed(Strings.outgoingFailed)
            }
        }
    }

    /// 보내는 글을 목록 맨 아래에 바로 올린다(결과는 `sendOwn` 이 갱신).
    private func enqueueOutgoing(_ pending: PendingOwn) -> Int64 {
        let id = nextOutgoingId
        nextOutgoingId -= 1
        outgoing[pending.room, default: []].append(OutgoingMessage(
            id: id, room: pending.room, kind: pending.kind, body: pending.body, attachment: pending.attachment,
            createdAt: Date(), clientId: nil, state: .sending))
        bumpRevision(pending.room)
        return id
    }

    private func updateOutgoing(_ id: Int64, room: RoomID, _ change: (inout OutgoingMessage) -> Void) {
        guard var list = outgoing[room], let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        outgoing[room] = list
        bumpRevision(room)
    }

    private func removeOutgoing(id: Int64? = nil, clientId: String? = nil, room: RoomID) {
        guard var list = outgoing[room] else { return }
        let before = list.count
        list.removeAll { ($0.id == id && id != nil) || ($0.clientId == clientId && clientId != nil) }
        guard list.count != before else { return }
        outgoing[room] = list.isEmpty ? nil : list
        bumpRevision(room)
    }

    /// 「다시 보내기」: 실패한 글을 같은 내용으로 다시 보낸다(새 보내는 글로).
    func retry(outgoingId: Int64, room: RoomID) async {
        guard let failed = outgoing[room]?.first(where: { $0.id == outgoingId }) else { return }
        removeOutgoing(id: outgoingId, room: room)
        switch failed.kind {
        case .attachment:
            if let data = failed.attachment { _ = await sendAttachment(room: room, data: data) }
        default:
            _ = await send(room: room, text: failed.body)
        }
    }

    /// 첨부(≤256 KiB, 원본 바이트 그대로 — AttachmentFormat). 한도 초과는 암호화 전에 `lastError` 로 거절한다.
    @discardableResult
    func sendAttachment(room: RoomID, data: Data) async -> SendOutcome? {
        guard data.count <= AttachmentFormat.maxBytes else { lastError = Strings.attachmentTooLarge(data.count); return nil }
        let pending = PendingOwn(room: room, kind: .attachment, body: AttachmentFormat.sniffMime(data), attachment: data)
        return await sendOwn(room: room, pending: pending, outgoing: enqueueOutgoing(pending)) { try await $0.send(attachment: data) }
    }

    /// 보내기 결과를 보내는 글(`outgoing`)에 반영한다: 받아 주면 빠지고 실제 기록이 잇는다 · 보관되면 「연결되면 보냅니다」 ·
    /// 실패하면 「전송 안 됨」(사유) + 다시 보내기. 실패 사유는 말풍선에 있으므로 화면 위 `lastError` 로 겹쳐 보이지 않는다.
    private func sendOwn(room: RoomID, pending: PendingOwn, outgoing id: Int64,
                         _ operation: @escaping (RoomSyncEngine) async throws -> SendOutcome) async -> SendOutcome? {
        guard case .ready = phase else {
            updateOutgoing(id, room: room) { $0.state = .failed(Strings.notReady) }
            return nil
        }
        do {
            let outcome = try await serial.run { try await operation(try self.syncEngine(room)) }
            switch outcome {
            case .sent(let clientId, let seq, _):
                unconfirmed[clientId] = pending
                removeOutgoing(id: id, room: room)
                try recordOwn(clientId: clientId, seq: seq)
                lastError = nil
                reconnecting = false
            case .queued(let clientId):
                // 릴레이에 닿지 않아 outbox 에 보관 — 연결되면 같은 바이트로 다시 보낸다(`recordOwn` 이 그때 지운다).
                unconfirmed[clientId] = pending
                updateOutgoing(id, room: room) { $0.clientId = clientId; $0.state = .queued }
                reconnecting = true
            case .reconciled:
                removeOutgoing(id: id, room: room)
                lastError = nil
                reconnecting = false
            }
            return outcome
        } catch SyncError.attachmentTooLarge(let size) {
            updateOutgoing(id, room: room) { $0.state = .failed(Strings.attachmentTooLarge(size)) }
        } catch SyncError.halted(let reason) {
            updateOutgoing(id, room: room) { $0.state = .failed(Strings.outgoingFailed) }
            halt(reason: reason, room: room)
        } catch SyncError.registrationPending {
            updateOutgoing(id, room: room) { $0.state = .failed(Strings.outgoingFailed) }
            phase = .needsEnrollment
        } catch SyncError.notJoined {
            updateOutgoing(id, room: room) { $0.state = .failed(Strings.notJoined) }
        } catch EngineError.rejected(let reason) {
            updateOutgoing(id, room: room) { $0.state = .failed(Strings.sendRejected(reason)) }
        } catch RelayError.refused(let code, let status) where !ConnectionIssue.isTransient(status: status) {
            // #497 B: 릴레이의 영구 거절(413 용량 등) — 엔진이 outbox 항목을 닫았다. 사람이 읽는 사유로 말풍선에만(날것의 오류 대신).
            updateOutgoing(id, room: room) { $0.state = .failed(Strings.sendRejected("\(status) \(code)")) }
        } catch {
            // 릴레이에 닿지 않음(취소 포함): 글은 「연결되면 보냅니다」로 남기고, 연결이 돌아온 첫 동기화 뒤에 다시 보낸다
            // (`resendUnsentLocked` — outbox 에 들어가기 전에 실패한 글이라 앱이 직접 다시 보낸다).
            switch ConnectionIssue.classify(error, taskCancelled: Task.isCancelled) {
            case .cancelled, .unreachable:
                updateOutgoing(id, room: room) { $0.state = .queued }
                reconnecting = true
            case .other:
                updateOutgoing(id, room: room) { $0.state = .failed("\(error)") }
                lastError = "\(error)"
            }
        }
        return nil
    }

    /// #497 B: outbox 에 보관됐던 내 글이 닫혔다(reconciled — 방이 움직여 409, 또는 영구 거절). 종전에는 `.sent` 만 처리해
    /// 말풍선이 「연결되면 보냅니다」에 영원히 남았다. 평문을 쥐고 있으면(`unconfirmed`) clientId 를 떼어 「연결되면 보냅니다」(outbox 밖)로
    /// 되돌린다 — 이 바퀴 뒤 `resendUnsent` 가 새로 암호화해 한 번 보낸다. 그 송신이 다시 거절되면 `sendOwn` 이 「전송 안 됨」으로
    /// 바꾸므로 되풀이되지 않는다. 평문이 없으면(재시작 뒤) 보일 말풍선도 없다.
    private func reopenReconciled(clientId: String) {
        guard let pending = unconfirmed.removeValue(forKey: clientId),
              let id = outgoing[pending.room]?.first(where: { $0.clientId == clientId })?.id else { return }
        updateOutgoing(id, room: pending.room) { $0.clientId = nil; $0.state = .queued }
    }

    /// 연결이 돌아왔다(동기화 성공): outbox 에 못 들어가고 「연결되면 보냅니다」로 남은 글을 같은 내용으로 다시 보낸다.
    /// outbox 에 있는 글(`clientId` 있음)은 `flushOutbox` 가 같은 바이트로 보내므로 여기서 건드리지 않는다.
    private func resendUnsent() async {
        let due = outgoing.values.flatMap { $0 }.filter { $0.state == .queued && $0.clientId == nil }
        for message in due {
            await retry(outgoingId: message.id, room: message.room)
        }
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
        /// 보내는 글이면 그 상태(실제 기록은 nil). seq 는 음수.
        var outgoing: OutgoingState? = nil
        var id: Int64 { record.seq }
    }

    /// 보내는 글을 타임라인 항목으로(실제 기록 뒤에 이어 붙인다).
    private func outgoingItems(room: RoomID) -> [TimelineItem] {
        (outgoing[room] ?? []).map { message in
            TimelineItem(record: MessageRecord(room: room, seq: message.id, senderDevice: deviceId, clientId: message.clientId ?? "",
                                               kind: message.kind, body: message.body, attachment: nil,
                                               receivedAt: message.createdAt, decryptedBy: .app),
                         attachmentBytes: message.attachment?.count ?? 0, outgoing: message.state)
        }
    }

    func messages(room: RoomID) -> [TimelineItem] {
        storedMessages(room: room) + outgoingItems(room: room)
    }

    /// 타임라인 창 = 방의 **최신** 500건(#469). 종전 `after: 0, limit: 500` 은 가장 오래된 500건이라 501번째부터
    /// — 내가 방금 보낸 글도 — 화면에 오르지 않았다(웹 `history-store.list` 와 같은 "최신 N건"으로 맞춤).
    static let timelineLimit = 500
    /// #472: 위로 끝까지 올라오면 창을 이만큼 넓혀 과거 글을 더 읽는다(저장소 API 추가 없이 `messageHeadsTail(limit:)` 의 창만 키운다).
    static let olderPage = 200
    /// 방별 타임라인 창(행 수). 기본 `timelineLimit`; `loadOlder` 가 넓히고 `resetTimelineWindow` 가 되돌린다(방을 나갈 때).
    private var timelineWindows: [RoomID: Int] = [:]
    /// 마지막 읽기가 창보다 적게 돌아온 방 = 가장 오래된 행까지 다 올렸다 — 더 읽을 것이 없다.
    private var timelineExhausted: Set<RoomID> = []

    func timelineWindow(room: RoomID) -> Int { timelineWindows[room] ?? Self.timelineLimit }

    /// 아직 위에 더 읽을 글이 있는가(마지막 `messages(room:)` 읽기 기준). 방을 한 번도 읽지 않았으면 true.
    func canLoadOlder(room: RoomID) -> Bool { !timelineExhausted.contains(room) }

    /// 창을 한 페이지 넓힌다. 다음 `messages(room:)` 가 더 오래된 행을 앞에 붙여 돌려준다. 더 읽을 것이 없으면 false(창 불변).
    /// `messagesRevision` 은 올리지 않는다 — 그 경로는 "새 글 → 최하단" 이라 과거 읽기에서 화면이 튀면 안 된다(RoomView 가 직접 다시 읽는다).
    @discardableResult
    func loadOlder(room: RoomID) -> Bool {
        guard canLoadOlder(room: room) else { return false }
        timelineWindows[room] = timelineWindow(room: room) + Self.olderPage
        return true
    }

    /// 방을 나가면 창을 기본으로 되돌린다(다음 진입은 다시 최신 500건, 폴링마다 큰 창을 읽지 않는다).
    func resetTimelineWindow(room: RoomID) {
        timelineWindows[room] = nil
        timelineExhausted.remove(room)
    }

    private func storedMessages(room: RoomID) -> [TimelineItem] {
        let window = timelineWindow(room: room)
        let items: [TimelineItem]
        if let loading = deps.messageStore as? AttachmentLoading,
           let heads = try? loading.messageHeadsTail(room: room, limit: window) {
            items = heads.map { TimelineItem(record: $0.record, attachmentBytes: $0.attachmentBytes) }
        } else {
            // 지연 로딩을 모르는 저장소(동결 `MessageStore` 만): 종전처럼 BLOB 포함으로 읽되 뒤 N 건만 올린다.
            let all = (try? deps.messageStore.messages(room: room, after: 0, limit: Int.max)) ?? []
            items = all.suffix(window).map { r in
                TimelineItem(record: MessageRecord(room: r.room, seq: r.seq, senderDevice: r.senderDevice, clientId: r.clientId, kind: r.kind,
                                                   body: r.body, attachment: nil, receivedAt: r.receivedAt, decryptedBy: r.decryptedBy),
                             attachmentBytes: r.attachment?.count ?? 0)
            }
        }
        // 창보다 적게 왔다 = 저장소의 가장 오래된 행까지 올렸다(#472).
        if items.count < window { timelineExhausted.insert(room) } else { timelineExhausted.remove(room) }
        return items
    }

    /// 첨부 본체(≤ `AttachmentFormat.maxBytes`). 말풍선이 보일 때 한 번 읽는다.
    func attachment(room: RoomID, seq: Int64) -> Data? {
        if let loading = deps.messageStore as? AttachmentLoading { return try? loading.attachment(room: room, seq: seq) }
        return (try? deps.messageStore.messages(room: room, after: seq - 1, limit: 1))?.first { $0.seq == seq }?.attachment
    }

    /// file-v2 설명자(#499) — `.fileV2` 행의 attachment 칸. **파일 키가 들어 있다** — 화면·공유에 쓰지 않고 `fileV2Bytes` 만 쓴다.
    func fileV2Descriptor(room: RoomID, seq: Int64) -> FileV2Format.Descriptor? {
        guard let data = attachment(room: room, seq: seq) else { return nil }
        return try? FileV2Format.parseDescriptor(data)
    }

    /// file-v2 첨부를 연다: 설명자 → `GET /v2/rooms/{room}/blobs/{blob}?device=<나>` → 길이·sha256·GCM·크기 검증(FILE-V2.md §4-3).
    /// 파일 바이트는 기기 이력에 보관하지 않는다(다시 볼 때 다시 받는다, §4-2). 실패는 던진다 — 말풍선이 「열 수 없음 — 다시 시도」.
    func fileV2Bytes(room: RoomID, seq: Int64) async throws -> Data {
        guard let descriptor = fileV2Descriptor(room: room, seq: seq) else { throw FileV2Format.Rejected(reason: "descriptor") }
        guard let transport, !deviceId.isEmpty else { throw RelayError.unauthorized }
        let ciphertext = try await transport.getBlob(room: room, device: deviceId, id: descriptor.blob)
        // 최대 50 MiB 해시·복호화는 메인 스레드 밖에서.
        return try await Task.detached(priority: .userInitiated) { try FileV2Format.open(ciphertext, descriptor) }.value
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
        // outbox 에서 나간 글(「연결되면 보냅니다」)은 이제 실제 기록이 잇는다.
        removeOutgoing(clientId: clientId, room: pending.room)
        if try deps.messageStore.messages(room: pending.room, after: seq - 1, limit: 1).first?.seq != seq {
            try deps.messageStore.insert(MessageRecord(room: pending.room, seq: seq, senderDevice: deviceId, clientId: clientId,
                                                       kind: pending.kind, body: pending.body, attachment: pending.attachment,
                                                       receivedAt: Date(), decryptedBy: .app))
        }
        bumpRevision(pending.room)
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

/// 오류 하나가 화면에 무엇이 되는가(오너 요청, build 29 스크린샷: `NSURLErrorDomain Code=-999 "취소됨"` 원문이 대화를 가림).
/// - `.cancelled`: 화면 `.task` 취소·백그라운드 전환으로 끊긴 요청(URLError -999 / CancellationError) — 장애가 아니다, 표시 안 함.
/// - `.unreachable`: 릴레이에 닿지 않음(네트워크 오류 · 게이트웨이 502~504) — 「연결 중입니다…」, 다음 바퀴가 다시 시도.
/// - `.other`: 그 밖(설정 오류 · 응답 해석 실패 · 거부 등) — `lastError` 로 보인다.
enum ConnectionIssue: Equatable {
    case cancelled, unreachable, other

    static func classify(_ error: Error, taskCancelled: Bool) -> ConnectionIssue {
        if taskCancelled || error is CancellationError { return .cancelled }
        if let urlError = error as? URLError { return urlError.code == .cancelled ? .cancelled : .unreachable }
        switch error as? RelayError {
        case .network(let detail)?:
            // URLSessionRelayTransport 는 URLError 를 문자열로 감싼다(`RelayError.network("\(error)")`).
            if detail.contains("NSURLErrorDomain Code=-999") { return .cancelled }
            if detail.hasPrefix("bad relay url") { return .other }
            return .unreachable
        case .refused(_, let status)? where isTransient(status: status):
            return .unreachable
        default:
            return .other
        }
    }

    /// 다시 시도하면 될 거절(게이트웨이 502~504 · 속도 제한 429) — `RoomSyncEngine.isTransientRefusal` 과 같은 기준(#497 B).
    static func isTransient(status: Int) -> Bool { status == 429 || (502...504).contains(status) }
}
