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
}

public enum SendOutcome: Equatable {
    /// 서버 확인. duplicate = 200(같은 바이트 재전송이 이미 저장돼 있었다).
    case sent(clientId: String, seq: Int64, duplicate: Bool)
    /// 네트워크 실패 — pending 으로 남아 `flushOutbox` 가 같은 바이트로 재시도한다.
    case queued(clientId: String)
    /// 재시작 등으로 평문이 없는 pending 항목이 409 를 받았다 — 재암호화할 수 없어 reconciled 로 닫았다.
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
            if pass.halted != nil || !pass.hasMore { break }
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
            try apply(page: page, cursor: cursor, engine: engine, dirty: &dirty)
        }
        // ③ 상태가 저장된 뒤에만: 방 기록 → 정지 사유 → 커서.
        epoch = max(epoch, page.epoch); revision = max(revision, page.revision)
        try persistRoom(halted: outcome.halted)
        if outcome.cursor > cursor { try cursors.setCursor(room: room, seq: outcome.cursor) }
        joined = outcome.joined
        outcome.fetched = page.events.count
        outcome.hasMore = outcome.halted == nil && page.events.count >= configuration.pageLimit
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
            case .application where joinedNow:
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
        // outer(릴레이가 추적하는 roster)는 이 commit 이 페이지의 최신 epoch 일 때만 비교한다.
        // 이 기기를 제거하는 commit 이면 응답에 roster 가 없으므로(#289) 내부 검사만.
        let removesMe = report.removes.contains { $0.id == identity }
        let outer: [String]? = (!removesMe && ev.epoch + 1 == page.epoch) ? page.members?.map(\.device) : nil
        switch CommitPolicy.checkCommit(report: report, roster: roster.map(\.id), committer: ev.device, outer: outer) {
        case .failure(let refusal):
            return refuse(refusal.reason.rawValue)
        case .success:
            do { _ = try engine.dispatch(.mergeStaged, Data()) }
            catch EngineError.rejected { return .rejected }
            return removesMe ? .removed : .applied
        }
    }

    /// application 1건: decrypt → MessageStore. 이미 저장된 seq 면(저장 실패 뒤 재처리) 다시 넣지 않는다.
    /// 반환 = 해독 성공 여부. 해독 불가도 화면에 보이도록 `undecryptable` 행을 남긴다.
    private func storeApplication(_ ev: StoredEvent, engine: MlsEngine, dirty: inout Bool) throws -> Bool {
        var record: MessageRecord
        var ok = true
        do {
            let output = try engine.dispatch(.decrypt, Framing.decryptInput(room: room, ciphertext: ev.bytes))
            dirty = true   // 수신 ratchet 전진 — 저장해야 한다
            let decrypted = try Framing.parseDecrypted(output)
            if decrypted.senderDevice == ev.device {
                record = MessageRecord(room: room, seq: ev.seq, senderDevice: decrypted.senderDevice, clientId: decrypted.clientId,
                                       kind: .text, body: String(decoding: decrypted.plaintext, as: UTF8.self),
                                       attachment: nil, receivedAt: Date(), decryptedBy: .app)
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
        if try messages.messages(room: room, after: ev.seq - 1, limit: 1).first?.seq != ev.seq {
            try messages.insert(record)
        }
        return ok
    }

    private func undecryptable(_ ev: StoredEvent, reason: String) -> MessageRecord {
        MessageRecord(room: room, seq: ev.seq, senderDevice: ev.device, clientId: ev.clientId, kind: .undecryptable,
                      body: reason, attachment: nil, receivedAt: Date(), decryptedBy: .app)
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

    /// 동기화 → encrypt → outbox(정확 바이트) → POST. 409 면 새 client_id 로 1회 재암호화.
    /// 먼저 동기화하는 것은 relay-app `send` 와 같다: 새 epoch·commit 을 적용한 뒤 암호화해야 409 가 드물고,
    /// 릴레이에 닿지 않으면 ratchet 을 쓰기 전에 실패한다(평문은 호출자가 들고 있다).
    public func send(plaintext: Data) async throws -> SendOutcome {
        if let haltedReason { throw SyncError.halted(haltedReason) }
        try await syncAll()
        if registrationPending != nil { throw SyncError.registrationPending }   // ratchet 을 쓰기 전에
        var retried = false
        while true {
            if let haltedReason { throw SyncError.halted(haltedReason) }
            let entry = try encryptAndEnqueue(plaintext)
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
            } catch where Self.isRegistrationRefusal(error) {
                // 바이트는 유효하다 — pending 으로 두고 등록 뒤 flushOutbox 가 같은 바이트로 보낸다.
                try markRegistrationPending()
                throw SyncError.registrationPending
            }
        }
    }

    /// pending outbox 항목을 **같은 바이트**로 다시 보낸다(K4). 409 는 평문이 없어 재암호화할 수 없으므로 reconciled.
    /// 네트워크 실패면 거기서 멈추고 남은 항목은 pending 으로 둔다.
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
            } catch where Self.isRegistrationRefusal(error) {
                try markRegistrationPending()
                outcomes.append(.queued(clientId: entry.clientId))
                break
            }
        }
        return outcomes
    }

    private func encryptAndEnqueue(_ plaintext: Data) throws -> OutboxEntry {
        let clientId = makeClientId()
        let bytes = try transaction { engine, dirty -> Data in
            guard try isJoined(engine) else { throw SyncError.notJoined }
            let ciphertext = try engine.dispatch(.encrypt, Framing.encryptInput(room: room, clientId: clientId, plaintext: plaintext))
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
