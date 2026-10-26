// 방 동기화 엔진 — CONTRACTS.md §2.2 클라이언트 규칙의 구현 (#276 L3, 설계 #271 §7·§12-C).
// relay-app.js `sync()`·봇 `session.rs poll_room` 과 같은 처리 순서를 프로토콜(MlsEngine·MlsStateStore·OutboxStore·
// CursorStore·MessageStore·RelayTransport)만으로 옮겼다. 앱·NSE 는 방마다 이 객체 하나를 쓴다(단일 호출자, 스레드 안전 아님).
//
// 수신 1회(`syncOnce`) = GET 1페이지 = 트랜잭션 1개:
//   ① GET events?after=<영속 커서>&ack=<영속 커서>  — 트랜잭션 **밖**
//   ② withExclusive { load → 엔진 연산들 → MessageStore 기록 → save }  — body 는 동기 클로저라 안에서 await 불가
//        - 이력 공백(joined ∧ first_seq > cursor+1) → 아무것도 처리하지 않고 ⛔ `history_gap`
//        - 내 이벤트: commit echo 이고 pending 이 있으면 merge_pending, 나머지는 건너뜀
//        - 참여 전: Welcome → join, 그 밖은 내 것이 아님(읽지 않음)
//        - 참여 후 Welcome → 무시 / 타인 commit → stage_commit → CommitPolicy ①~④ → merge_staged | discard_staged + ⛔
//        - application → decrypt → MessageStore.insert (거부 = `undecryptable` 행, 엔진은 연산 전 스냅샷으로 복원됨)
//   ③ 커밋된 뒤에만 RoomRecord(epoch·revision·정지 사유) 갱신 → CursorStore.setCursor → 다음 GET 의 ?ack=
//
// 두 프로세스(App ∥ NSE, #271 §4·§8 — 같은 App Group 의 flock)가 같은 방을 처리할 때(파이널라이저 결정 D4):
//   네트워크는 락 밖이라 둘이 같은 커서로 같은 페이지를 받을 수 있고, 커서는 상태 커밋·unlock **뒤**에 쓰인다.
//   그래서 트랜잭션 안에서 (a) 영속 커서를 다시 읽어 그 이하는 건너뛰고 (b) `MessageStore` 에 이미 있는 seq 의 application 은
//   **복호화하지 않는다**(행은 상태 저장과 같은 락 안에서 기록되므로 "다른 쪽이 처리했다" 의 증거) (c) 커서는 단조(max)로만 움직인다.
//   남는 창(상대가 상태를 커밋한 뒤 커서를 쓰기 전 죽음)의 타인 commit 재처리는 엔진이 에폭 불일치로 거부·복원한다(무해).
//
// 송신(`send`): 동기화 → 트랜잭션 { encrypt → save } → OutboxStore.enqueue(정확 바이트) → POST(밖).
//   409 cas_mismatch → 옛 항목 reconciled → clear_pending(대기 commit 이 있으면) → 동기화 → **새 client_id 로 재암호화** 1회.
//   네트워크 실패 → 항목은 pending 으로 남고 `flushOutbox` 가 **같은 바이트**로 재시도(201 또는 200 duplicate).
//
// 등록 대기: 403 `device_subject_mismatch`(정책 체인에 아직 없는 기기) → ⛔ 정지가 아니라 `registrationPending`
//   (등록 JSON = `EnrollmentRequest`). 영속하지 않고 다음 폴링마다 다시 묻는다 — 운영자가 등록하면 그 GET 이 성공해 풀린다.
//   송신 중이면 outbox 항목은 pending 으로 남아 등록 뒤 같은 바이트로 나간다.
import Foundation

/// ⛔ 정지 사유 문자열. commit 정책 거부는 `CommitRefusalReason.rawValue` 를 그대로 쓴다(웹·봇과 같은 토큰).
public enum SyncHaltReason {
    public static let historyGap = "history_gap"
    /// 검증된 commit 이 이 기기를 제거했다 — 그 뒤로는 읽을 수 없다(relay-app #289).
    public static let removedFromRoom = "removed_from_room"
    /// stage_commit 출력이 stage report 형식이 아니다(봇 `report_format`).
    public static let reportFormat = "report_format"
    /// 현재 roster 를 엔진에서 읽지 못했다(봇 `roster_unavailable`).
    public static let rosterUnavailable = "roster_unavailable"
    public static let roomClosed = "room_closed"
}

public enum SyncError: Error, Equatable {
    /// 방이 ⛔ 정지 상태 — 운영자 조치(재추가) 전에는 읽기·송신하지 않는다.
    case halted(String)
    /// 아직 이 방 그룹에 참여하지 않았다(Welcome 전).
    case notJoined
    /// 409 → 동기화 → 재암호화 뒤에도 다시 409.
    case casRetryExhausted
    /// 릴레이가 이 기기를 아직 받지 않는다(403 device_subject_mismatch) — 운영자 등록 대기.
    case registrationPending
    /// 첨부가 `AttachmentFormat.maxBytes` 를 넘는다(암호화 전 거부 — ratchet 을 쓰지 않는다).
    case attachmentTooLarge(Int)
}

/// `syncOnce` 1회의 결과(화면·로그·테스트용).
public struct SyncPass: Equatable {
    public var fetched: Int = 0
    /// 이 패스 뒤 영속 커서.
    public var cursor: Int64 = 0
    /// 이 패스에서 MessageStore 에 새로 들어간 seq.
    public var inserted: [Int64] = []
    /// 엔진이 거부해 건너뛴 seq(poison commit/Welcome, 해독 불가 application).
    public var rejected: [Int64] = []
    public var joined: Bool = false
    public var halted: String?
    /// 403 device_subject_mismatch — 운영자 등록 대기(`RoomSyncEngine.registrationPending`).
    public var registrationPending: Bool = false
    /// 같은 페이지 크기만큼 받았다 — 더 있을 수 있다.
    public var hasMore: Bool = false
    /// `Configuration.maxApplicationBytes` 를 넘는 application 이벤트에서 멈췄다(커서는 그 앞). 제한 없는 호출자(앱)가 처리한다.
    public var deferredSeq: Int64? = nil
}

public enum SendOutcome: Equatable {
    /// 서버 확인. duplicate = 200(같은 바이트 재전송이 이미 저장돼 있었다).
    case sent(clientId: String, seq: Int64, duplicate: Bool)
    /// 네트워크 실패 — pending 으로 남아 `flushOutbox` 가 같은 바이트로 재시도한다.
    case queued(clientId: String)
    /// 재시작 등으로 평문이 없는 pending 항목이 409 를 받았다 — 재암호화할 수 없어 reconciled 로 닫았다.
    /// #497 B: `flushOutbox` 의 영구 거절(413 등)도 여기로 닫는다. 평문을 쥔 호출자는 다시 암호화해 보내면 된다.
    case reconciled(clientId: String)
}

public final class RoomSyncEngine {
    public struct Configuration {
        /// 앱 기본. NSE 는 ≤5s(CONTRACTS §3.1) 안에서 더 짧게.
        public var lockTimeout: TimeInterval = 5
        public var pageLimit: Int = 500
        /// 전면 폴링 주기(CONTRACTS §2.2).
        public var pollInterval: TimeInterval = 4
        /// 확인된 outbox 장부 상한(#177 §3.5).
        public var outboxKeep: Int = 256
        /// `syncAll` 한 번에 따라가는 최대 페이지 수.
        public var maxPages: Int = 20
        /// 복호화한 프로세스 표시(`MessageRecord.decryptedBy`). NSE 는 `.nse`.
        public var decryptedBy: MessageRecord.DecryptedBy = .app
        /// 이 크기(암호문 바이트)를 넘는 application 이벤트는 처리하지 않고 **그 앞에서 페이지를 끝낸다**(`SyncPass.deferredSeq`,
        /// 커서는 그 앞에 머문다). NSE(24 MB 예산)가 5 MiB 첨부(#364)를 피하고 앱에 넘기는 장치. nil = 제한 없음(앱).
        public var maxApplicationBytes: Int? = nil
        public init() {}
    }

    public let room: RoomID
    public let identity: DeviceID
    public let configuration: Configuration

    private let engineFactory: MlsEngineFactory
    private let stateStore: MlsStateStore
    private let outbox: OutboxStore
    private let cursors: CursorStore
    private let messages: MessageStore
    private let transport: RelayTransport
    private let makeClientId: () -> String
    private let enrollmentSubject: String

    /// 마지막으로 저장(또는 로드)한 엔진과 그 generation. 다른 작성자(NSE)가 사이에 쓰면 generation 이 달라져 다시 import 한다.
    private var cached: (generation: UInt64, engine: MlsEngine)?
    private var ackSent: Int64 = 0
    private var ackDisabled = false
    /// 마지막으로 본 릴레이 epoch — POST 의 CAS 값.
    public private(set) var epoch: Int64 = 0
    public private(set) var revision: Int64 = 0
    public private(set) var joined = false
    public private(set) var haltedReason: String?
    /// nil 이 아니면 "운영자 등록 대기" 화면에 이 JSON 을 보여 준다(`EnrollmentRequest.json()`).
    public private(set) var registrationPending: EnrollmentRequest?

    public init(room: RoomID, identity: DeviceID, engineFactory: MlsEngineFactory, stateStore: MlsStateStore,
                outbox: OutboxStore, cursors: CursorStore, messages: MessageStore, transport: RelayTransport,
                configuration: Configuration = Configuration(),
                enrollmentSubject: String = "",
                makeClientId: (() -> String)? = nil) throws {
        self.room = room; self.identity = identity; self.configuration = configuration
        self.enrollmentSubject = enrollmentSubject
        self.engineFactory = engineFactory; self.stateStore = stateStore
        self.outbox = outbox; self.cursors = cursors; self.messages = messages; self.transport = transport
        self.makeClientId = makeClientId ?? { "\(identity)-\(UUID().uuidString.prefix(8).lowercased())" }
        // 재시작 뒤에도 ⛔ 정지는 유지(relay-app localStorage 상당 = rooms.halted_reason).
        if let record = try messages.rooms().first(where: { $0.room == room }) {
            epoch = record.epoch; revision = record.revision; haltedReason = record.haltedReason
        }
    }

    // MARK: - 트랜잭션 (엔진 연산·상태 저장은 여기 안에서만)

    /// load → body(엔진 연산) → dirty 면 save. body 는 동기라 네트워크를 부를 수 없다(CONTRACTS §2.2·§3.4).
    /// body 가 throw 하면 저장소가 디스크를 되돌리고, 메모리의 엔진 캐시도 버린다.
    private func transaction<T>(_ body: (MlsEngine, inout Bool) throws -> T) throws -> T {
        do {
            return try stateStore.withExclusive(room: room, timeout: configuration.lockTimeout) { tx in
                let engine: MlsEngine
                var dirty = false
                if let cached, cached.generation == tx.generation {
                    engine = cached.engine
                } else if let bytes = try tx.load() {
                    engine = try engineFactory.importState(identity: identity, bytes: bytes)
                } else {
                    // 상태 없음: 새 기기. 첫 트랜잭션에서 바로 저장한다 — 안 그러면 매번 새 서명키가 생긴다(등록 JSON 이 흔들림).
                    // 키 패키지 발행(상태 시드)은 호출자 몫 — 시드가 없으면 Welcome join 은 엔진이 거부한다.
                    engine = try engineFactory.create(identity: identity)
                    dirty = true
                }
                let result = try body(engine, &dirty)
                if dirty {
                    try tx.save(try engine.exportState())
                    cached = (tx.generation + 1, engine)
                } else {
                    cached = (tx.generation, engine)
                }
                return result
            }
        } catch {
            cached = nil
            throw error
        }
    }

    /// 이 기기가 그룹 멤버인가 — 엔진 `members`(roster 프레임)에 내 ID 가 있으면 참여 상태.
    /// 그룹이 없으면 파사드가 `.rejected`. `.invalid`(L2 메서드 부재)는 호스트 전제 위반이라 그대로 던진다.
    private func isJoined(_ engine: MlsEngine) throws -> Bool {
        do {
            let frame = try engine.dispatch(.members, Data())
            return CommitPolicy.parseRosterFrame(frame)?.contains { $0.id == identity } ?? false
        } catch EngineError.rejected {
            return false
        }
    }

    // MARK: - 수신

    /// 남은 페이지를 끝까지(최대 `maxPages`) 따라간다. 정지하면 거기서 멈춘다.
    @discardableResult
    public func syncAll() async throws -> [SyncPass] {
        var passes: [SyncPass] = []
        for _ in 0..<max(configuration.maxPages, 1) {
            let pass = try await syncOnce()
            passes.append(pass)
            if pass.halted != nil || pass.deferredSeq != nil || !pass.hasMore { break }
        }
        return passes
    }

    /// GET 1페이지를 처리한다(위 파일 머리말 ①~③).
    @discardableResult
    public func syncOnce() async throws -> SyncPass {
        if let haltedReason { return SyncPass(cursor: try cursors.cursor(room: room), joined: joined, halted: haltedReason) }
        let cursor = try cursors.cursor(room: room)
        // ack 는 영속된 커서만, 참여한 기기만(아니면 403 not_a_member), 같은 값은 다시 보내지 않는다(봇 B-H4).
        let ack: Int64? = (joined && !ackDisabled && cursor > ackSent) ? cursor : nil
        let page: EventsPage
        do {
            page = try await transport.getEvents(room: room, device: identity, after: cursor, limit: configuration.pageLimit, ack: ack)
        } catch let RelayError.refused(code, status) {
            return try handleReadRefusal(code: code, status: status, ack: ack, cursor: cursor)
        }
        if let ack { ackSent = ack }
        registrationPending = nil   // 릴레이가 받았다 = 등록됨

        var outcome = try transaction { engine, dirty in
            // D4(a): 락을 잡은 지금의 영속 커서 — GET 사이에 다른 프로세스가 처리·영속한 seq 는 다시 보지 않는다.
            try apply(page: page, cursor: max(cursor, try cursors.cursor(room: room)), engine: engine, dirty: &dirty)
        }
        // ③ 상태가 저장된 뒤에만: 방 기록 → 정지 사유 → 커서(D4(c): 단조 — 다른 프로세스가 더 멀리 갔으면 되돌리지 않는다).
        epoch = max(epoch, page.epoch); revision = max(revision, page.revision)
        try persistRoom(halted: outcome.halted)
        let persisted = try cursors.cursor(room: room)
        if outcome.cursor > persisted { try cursors.setCursor(room: room, seq: outcome.cursor) }
        outcome.cursor = max(outcome.cursor, persisted)
        joined = outcome.joined
        outcome.fetched = page.events.count
        outcome.hasMore = outcome.halted == nil && outcome.deferredSeq == nil && page.events.count >= configuration.pageLimit
        return outcome
    }

    private func handleReadRefusal(code: String, status: Int, ack: Int64?, cursor: Int64) throws -> SyncPass {
        // 방이 아직 없다(첫 commit 전) — 오류가 아니라 볼 것이 없음.
        if status == 404 && code == "no_such_room" { return SyncPass(cursor: cursor, joined: joined) }
        // 릴레이가 ack 를 거부(방 리셋 뒤 bad_ack, 제거 뒤 not_a_member) → ack 만 끈다, 세션은 계속(봇과 같음).
        if ack != nil && ((status == 400 && code == "bad_ack") || (status == 403 && code == RelayErrorCode.notAMember.rawValue)) {
            ackDisabled = true
            return SyncPass(cursor: cursor, joined: joined)
        }
        if status == 403 && code == RelayErrorCode.deviceSubjectMismatch.rawValue {
            try markRegistrationPending()
            return SyncPass(cursor: cursor, joined: joined, registrationPending: true)
        }
        if code == RelayErrorCode.roomClosed.rawValue {
            try persistRoom(halted: SyncHaltReason.roomClosed)
            return SyncPass(cursor: cursor, joined: joined, halted: SyncHaltReason.roomClosed)
        }
        throw RelayError.refused(code: code, status: status)
    }

    /// 등록 JSON 을 엔진의 공개 정보로 만든다(트랜잭션 안: 새 기기면 이때 상태가 저장된다).
    private func markRegistrationPending() throws {
        registrationPending = try transaction { engine, _ in try EnrollmentRequest(engine: engine, subject: enrollmentSubject) }
    }

    /// #497 B: 다시 보내면 될 거절 — 게이트웨이(502~504: 엣지·터널이 릴레이에 못 닿음, 504 는 릴레이가 이미 저장했을 수도)와
    /// 429(속도 제한). 같은 바이트·같은 client_id 재전송은 릴레이가 `200 duplicate` 로 받으므로 두 번 저장되지 않는다.
    /// 종전에는 이 거절이 `send`·`flushOutbox` 밖으로 던져져, 앱이 outbox 에 이미 있는 글을 **재암호화해 한 번 더** 보냈다(사진 이중 전송).
    static func isTransientRefusal(_ error: Error) -> Bool {
        if case RelayError.refused(_, let status) = error { return status == 429 || (502...504).contains(status) }
        return false
    }

    private static func isRegistrationRefusal(_ error: Error) -> Bool {
        if case RelayError.refused(let code, let status) = error {
            return status == 403 && code == RelayErrorCode.deviceSubjectMismatch.rawValue
        }
        return false
    }

    private enum CommitVerdict { case applied, rejected, refused(String), removed }

    /// 트랜잭션 안: 한 페이지의 이벤트를 순서대로 적용한다. 네트워크 없음.
    private func apply(page: EventsPage, cursor: Int64, engine: MlsEngine, dirty: inout Bool) throws -> SyncPass {
        var pass = SyncPass(cursor: cursor)
        var joinedNow = try isJoined(engine)
        pass.joined = joinedNow
        // #268: 참여한 기기가 읽지 못한 seq 를 릴레이가 지웠다 → 페이지의 어떤 것도 커서를 움직이기 전에 정지.
        if joinedNow, let first = page.firstSeq, first > 0, first > cursor + 1 {
            pass.halted = SyncHaltReason.historyGap
            return pass
        }
        for ev in page.events where ev.seq > pass.cursor {
            if ev.device == identity {
                // 내 echo. MLS 는 자기 메시지를 처리하지 않는다 — 내 commit 의 echo 가 merge_pending 의 자리.
                if ev.kind == .commit, joinedNow, try engine.hasPending() {
                    do { _ = try engine.dispatch(.mergePending, Data()); dirty = true }
                    catch EngineError.rejected { pass.rejected.append(ev.seq) }
                }
                pass.cursor = ev.seq
                continue
            }
            switch ev.kind {
            case .welcome where !joinedNow:
                do {
                    _ = try engine.dispatch(.join, ev.bytes)
                    dirty = true
                    joinedNow = try isJoined(engine)
                } catch EngineError.rejected {
                    pass.rejected.append(ev.seq)   // poison Welcome: 엔진 복원됨, 건너뜀
                }
            case .welcome:
                break   // 이미 참여한 기기에 온 Welcome(재초대) — 무시, 치명 아님
            case .commit where joinedNow:
                switch try applyForeignCommit(ev, page: page, engine: engine) {
                case .applied:
                    dirty = true
                case .rejected:
                    pass.rejected.append(ev.seq)
                case .refused(let reason):
                    // 거부된 commit 은 지나가지 않는다: 커서는 그 앞에 머물러 릴레이 보존(pruning gate)을 붙든다.
                    dirty = true
                    pass.halted = reason
                    pass.joined = joinedNow
                    return pass
                case .removed:
                    dirty = true
                    pass.cursor = ev.seq
                    pass.halted = SyncHaltReason.removedFromRoom
                    pass.joined = false
                    return pass
                }
            case .application where joinedNow && configuration.maxApplicationBytes.map({ ev.bytes.count > $0 }) == true:
                // 큰 첨부(#364): 이 프로세스의 예산을 넘는다 — 커서를 여기 앞에 두고 페이지를 끝낸다. 제한 없는 앱이 이어서 처리한다.
                pass.deferredSeq = ev.seq
                pass.joined = joinedNow
                return pass
            case .application where joinedNow:
                if try isStored(ev.seq) {
                    break   // D4(b): 다른 프로세스가 이미 복호화·기록했다 — MLS 는 같은 메시지를 다시 풀 수 없다(재시도 = 거부)
                }
                if try storeApplication(ev, engine: engine, dirty: &dirty) { pass.inserted.append(ev.seq) }
                else { pass.rejected.append(ev.seq) }
            default:
                break   // Welcome 이전의 commit·application 은 이 기기가 읽을 것이 아니다
            }
            pass.cursor = ev.seq
        }
        pass.joined = joinedNow
        return pass
    }

    /// 타인 commit 2단계 적용(#261/#263): stage → 정책 → merge | discard.
    private func applyForeignCommit(_ ev: StoredEvent, page: EventsPage, engine: MlsEngine) throws -> CommitVerdict {
        let reportBytes: Data
        do { reportBytes = try engine.dispatch(.stageCommit, ev.bytes) }
        catch EngineError.rejected { return .rejected }   // poison commit — 엔진은 stage 전으로 복원
        func refuse(_ reason: String) -> CommitVerdict {
            _ = try? engine.dispatch(.discardStaged, Data())   // 순수: staged 만 버리고 epoch 유지
            return .refused(reason)
        }
        guard let report = CommitPolicy.parseStageReport(reportBytes) else { return refuse(SyncHaltReason.reportFormat) }
        guard let frame = try? engine.dispatch(.members, Data()), let roster = CommitPolicy.parseRosterFrame(frame) else {
            return refuse(SyncHaltReason.rosterUnavailable)
        }
        // outer(릴레이가 추적하는 roster)는 이 commit 이 페이지의 최신 epoch 일 때 비교한다 — 이 기기를 제거하는
        // commit 도(#295 F1: 릴레이는 모든 독자에게 roster 를 준다). 멤버십을 추적하지 않는 릴레이(members 빔)만 예외.
        let removesMe = report.removes.contains { $0.id == identity }
        let outer = CommitPolicy.outerForCommit(report: report, identity: identity, eventEpoch: ev.epoch,
                                                pageEpoch: page.epoch, members: page.members)
        switch CommitPolicy.checkCommit(report: report, roster: roster.map(\.id), committer: ev.device, outer: outer) {
        case .failure(let refusal):
            return refuse(refusal.reason.rawValue)
        case .success:
            do { _ = try engine.dispatch(.mergeStaged, Data()) }
            catch EngineError.rejected { return .rejected }
            return removesMe ? .removed : .applied
        }
    }

    private func isStored(_ seq: Int64) throws -> Bool {
        try messages.messages(room: room, after: seq - 1, limit: 1).first?.seq == seq
    }

    /// application 1건: decrypt → MessageStore. 이미 저장된 seq 면(저장 실패 뒤 재처리) 다시 넣지 않는다.
    /// 반환 = 해독 성공 여부. 해독 불가도 화면에 보이도록 `undecryptable` 행을 남긴다.
    private func storeApplication(_ ev: StoredEvent, engine: MlsEngine, dirty: inout Bool) throws -> Bool {
        var record: MessageRecord
        var ok = true
        // #405 시간 표시: 메시지 시각 = 릴레이가 기록한 시각(`created_at`, Unix 초). 복호화한 순간(Date())을 쓰면
        // 앱을 오래 닫아 뒀다가 열었을 때 밀린 메시지가 모두 연 시각으로 찍힌다. 값이 없으면(0) 지금.
        let sentAt = Self.sentAt(ev)
        do {
            let output = try engine.dispatch(.decrypt, Framing.decryptInput(room: room, ciphertext: ev.bytes))
            dirty = true   // 수신 ratchet 전진 — 저장해야 한다
            let decrypted = try Framing.parseDecrypted(output)
            if decrypted.senderDevice == ev.device {
                // clientId = 릴레이 행의 dedup 키(AAD client_id 는 항상 발신 기기 ID 라 구분 정보가 없다).
                // 첨부 판정은 relay-app 과 같다: 바깥 client_id 가 `file-v1-<uuid>` 면 바이트를 첨부로, 아니면 UTF-8 텍스트로(AttachmentFormat).
                if AttachmentFormat.isAttachment(clientId: ev.clientId) {
                    record = MessageRecord(room: room, seq: ev.seq, senderDevice: decrypted.senderDevice, clientId: ev.clientId,
                                           kind: .attachment, body: AttachmentFormat.sniffMime(decrypted.plaintext),
                                           attachment: decrypted.plaintext, receivedAt: sentAt, decryptedBy: configuration.decryptedBy)
                } else {
                    record = MessageRecord(room: room, seq: ev.seq, senderDevice: decrypted.senderDevice, clientId: ev.clientId,
                                           kind: .text, body: String(decoding: decrypted.plaintext, as: UTF8.self),
                                           attachment: nil, receivedAt: sentAt, decryptedBy: configuration.decryptedBy)
                }
            } else {
                // 릴레이 row 의 기기와 MLS 발신자가 다르다 — 내용을 보이지 않는다.
                ok = false
                record = undecryptable(ev, reason: "sender_mismatch")
            }
        } catch EngineError.rejected(let reason) {
            ok = false
            record = undecryptable(ev, reason: reason)
        } catch is Framing.FramingError {
            ok = false
            record = undecryptable(ev, reason: "decrypt_format")
        }
        if try !isStored(ev.seq) {
            try messages.insert(record)
        }
        return ok
    }

    private func undecryptable(_ ev: StoredEvent, reason: String) -> MessageRecord {
        MessageRecord(room: room, seq: ev.seq, senderDevice: ev.device, clientId: ev.clientId, kind: .undecryptable,
                      body: reason, attachment: nil, receivedAt: Self.sentAt(ev), decryptedBy: configuration.decryptedBy)
    }

    /// 릴레이 기록 시각(`created_at`, Unix 초) — 없으면(0) 지금.
    static func sentAt(_ ev: StoredEvent) -> Date {
        ev.createdAt > 0 ? Date(timeIntervalSince1970: TimeInterval(ev.createdAt)) : Date()
    }

    private func persistRoom(halted: String?) throws {
        var record = try messages.rooms().first(where: { $0.room == room })
            ?? RoomRecord(room: room, epoch: 0, revision: 0, haltedReason: nil, displayOrder: 0)
        record.epoch = epoch; record.revision = revision
        if let halted { record.haltedReason = halted }
        try messages.upsertRoom(record)
        if let halted {
            try messages.setHalted(room: room, reason: halted)
            haltedReason = halted
        }
    }

    // MARK: - 송신

    public func send(text: String) async throws -> SendOutcome {
        try await send(plaintext: Data(text.utf8))
    }

    /// 첨부(원본 바이트 그대로, ≤256 KiB): 릴레이 client_id 만 `file-v1-<uuid>` 로 바꾼다(AttachmentFormat). 409 재암호화도 새 `file-v1-` ID.
    public func send(attachment: Data) async throws -> SendOutcome {
        guard attachment.count <= AttachmentFormat.maxBytes else { throw SyncError.attachmentTooLarge(attachment.count) }
        return try await send(plaintext: attachment, clientId: { AttachmentFormat.newClientId() })
    }

    /// 동기화 → encrypt → outbox(정확 바이트) → POST. 409 면 새 client_id 로 1회 재암호화.
    /// 먼저 동기화하는 것은 relay-app `send` 와 같다: 새 epoch·commit 을 적용한 뒤 암호화해야 409 가 드물고,
    /// 릴레이에 닿지 않으면 ratchet 을 쓰기 전에 실패한다(평문은 호출자가 들고 있다).
    /// `clientId` = 릴레이 dedup 키 생성기(기본 = 생성자의 `makeClientId`; 첨부는 `file-v1-` 접두). 시도마다 새로 부른다.
    public func send(plaintext: Data, clientId: (() -> String)? = nil) async throws -> SendOutcome {
        if let haltedReason { throw SyncError.halted(haltedReason) }
        try await syncAll()
        var retried = false
        while true {
            if let haltedReason { throw SyncError.halted(haltedReason) }
            if registrationPending != nil { throw SyncError.registrationPending }   // 409 뒤 재동기화에서 403 이 났을 수도
            let entry = try encryptAndEnqueue(plaintext, clientId: (clientId ?? makeClientId)())
            do {
                return try await post(entry)
            } catch RelayError.cas {
                // 방이 움직였다: 이 바이트는 영영 못 들어간다 → reconciled. 대기 commit 은 버리고 동기화 후 새 epoch 로 다시.
                try outbox.mark(room: room, clientId: entry.clientId, status: .reconciled)
                if retried { throw SyncError.casRetryExhausted }
                retried = true
                try transaction { engine, dirty in
                    if try engine.hasPending() { _ = try engine.dispatch(.clearPending, Data()); dirty = true }
                }
                try await syncAll()
            } catch RelayError.network {
                return .queued(clientId: entry.clientId)
            } catch where Self.isTransientRefusal(error) {
                // #497 B: 네트워크 실패와 같다 — pending 그대로, flushOutbox 가 같은 바이트로.
                return .queued(clientId: entry.clientId)
            } catch where Self.isRegistrationRefusal(error) {
                // 바이트는 유효하다 — pending 으로 두고 등록 뒤 flushOutbox 가 같은 바이트로 보낸다.
                try markRegistrationPending()
                throw SyncError.registrationPending
            } catch RelayError.refused(let code, let status) {
                // #497 B: 영구 거절(413 용량·400·403·410 등) — 같은 바이트는 다시 보내도 같다. 닫아서 폴링마다 다시 올리지 않게 하고
                // 호출자에게 그대로 알린다(평문을 쥔 호출자가 「전송 안 됨」으로 보인다).
                try outbox.mark(room: room, clientId: entry.clientId, status: .reconciled)
                throw RelayError.refused(code: code, status: status)
            }
        }
    }

    /// pending outbox 항목을 **같은 바이트**로 다시 보낸다(K4). 409 는 평문이 없어 재암호화할 수 없으므로 reconciled.
    /// 네트워크 실패·게이트웨이 502~504·429 면 거기서 멈추고 남은 항목은 pending 으로 둔다. 그 밖의 거절(413 등)은 그 항목만
    /// reconciled 로 닫고 계속한다(#497 B — 던지지 않는다).
    @discardableResult
    public func flushOutbox() async throws -> [SendOutcome] {
        var outcomes: [SendOutcome] = []
        for entry in try outbox.pending(room: room) {
            do {
                outcomes.append(try await post(entry))
            } catch RelayError.cas {
                try outbox.mark(room: room, clientId: entry.clientId, status: .reconciled)
                outcomes.append(.reconciled(clientId: entry.clientId))
            } catch RelayError.network {
                outcomes.append(.queued(clientId: entry.clientId))
                break
            } catch where Self.isTransientRefusal(error) {
                outcomes.append(.queued(clientId: entry.clientId))
                break
            } catch where Self.isRegistrationRefusal(error) {
                try markRegistrationPending()
                outcomes.append(.queued(clientId: entry.clientId))
                break
            } catch RelayError.refused {
                // #497 B: 영구 거절 — 종전에는 여기서 던져져 앱의 동기화 바퀴 전체(뒤의 방들·푸시·로비)가 멈추고, 4초마다 같은 바이트를
                // 다시 올렸다. 닫고(reconciled) 다음 항목으로 — 평문을 쥔 호출자(앱)가 다시 암호화해 보내거나 실패로 보인다.
                try outbox.mark(room: room, clientId: entry.clientId, status: .reconciled)
                outcomes.append(.reconciled(clientId: entry.clientId))
            }
        }
        return outcomes
    }

    private func encryptAndEnqueue(_ plaintext: Data, clientId: String) throws -> OutboxEntry {
        let bytes = try transaction { engine, dirty -> Data in
            guard try isJoined(engine) else { throw SyncError.notJoined }
            // AAD client_id 는 **기기 ID**(파사드 리뷰 H1: 수신측 decrypt 가 인증된 발신 기기와 같지 않으면 거부, 봇 session.rs 와 같음).
            // `clientId` 는 릴레이 행의 dedup 키(outbox·POST)로만 쓴다 — 둘을 섞으면 실 엔진에서 모든 수신이 거부된다.
            let ciphertext = try engine.dispatch(.encrypt, Framing.encryptInput(room: room, clientId: identity, plaintext: plaintext))
            dirty = true   // 송신 ratchet 전진 — 바이트가 나가기 전에 저장(봇 B-H2)
            return ciphertext
        }
        // 상태 저장 뒤 outbox: 저장이 실패하면 outbox 에도 없다(같은 sender generation 의 재사용 금지).
        let entry = OutboxEntry(room: room, clientId: clientId, kind: EventKind.application.rawValue, epoch: epoch,
                                bytes: bytes, status: .pending, createdAt: Date())
        try outbox.enqueue(entry)
        return entry
    }

    private func post(_ entry: OutboxEntry) async throws -> SendOutcome {
        let post = EventPost(device: identity, clientId: entry.clientId, kind: EventKind(rawValue: entry.kind) ?? .application,
                             epoch: entry.epoch, bytes: entry.bytes)
        let response = try await transport.postEvent(room: room, post)
        try outbox.mark(room: room, clientId: entry.clientId, status: .sent)
        try outbox.prune(room: room, keepingLast: configuration.outboxKeep)
        return .sent(clientId: entry.clientId, seq: response.seq, duplicate: response.duplicate)
    }

    // MARK: - 전면 폴링

    /// 포그라운드 폴링: 동기화 → outbox 비우기 → `pollInterval` 대기. 취소·정지되면 끝난다. 백그라운드는 푸시 wake(파이널라이저).
    /// 오류는 `onError` 로 알리고 다음 주기에 다시 시도한다.
    public func runForeground(onError: (Error) -> Void = { _ in },
                              sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) async {
        while !Task.isCancelled {
            do {
                try await syncAll()
                // 등록 대기 중에는 outbox 를 건드리지 않는다(같은 403 만 받는다) — 폴링은 계속해 등록되면 풀린다.
                if haltedReason == nil && registrationPending == nil { try await flushOutbox() }
            } catch {
                onError(error)
            }
            if haltedReason != nil { return }
            do { try await sleep(configuration.pollInterval) } catch { return }
        }
    }
}
