// NSE 처리 (§12-D, #271 §8, 파이널라이저 결정 D4·D5 — NOTES-FINALIZER.md). 플랫폼 무관(UserNotifications 는 FamilyChatNSE 쪽).
//
//   payload {room, seq} → 자격증명·기기 ID(공유 저장) → **App 과 같은 `RoomSyncEngine`**(같은 App Group 의 flock 단일 작성자,
//   방 상태가 없을 때의 시드도 같은 `SeededEngineFactory`) → syncAll(commit·application 처리, messages.db 기록, 원자 영속)
//   → 그 seq 의 행(NSE 든 App 이든 먼저 처리한 쪽이 기록)으로 알림 치환: 제목 = actor(봇이면 "🤖 actor"), 본문 = 텍스트/「사진」/「파일」.
//
// 절대 빈손 없음: 페이로드 이상·자격증명/기기 ID 없음·방 모름·락 대기 초과·네트워크·401·정지·해독 불가·행 없음·예외 → 전부
// "새 메시지가 도착했습니다". 기한은 `NotificationDeadline` 이 따로 건다(시스템 30 s 보다 짧게) — 넘으면 대체 알림을 먼저 내고,
// 남은 작업은 끝까지 가거나 프로세스와 함께 죽는다(상태는 원자 영속·flock 은 fd 와 함께 풀린다 → 손상 없음, D4 가 재처리를 막는다).
import Foundation
import FamilyMLSCore

/// 알림에 넣을 내용. `outcome` 은 테스트·로그용(사용자에게 보이지 않는다).
struct ProcessedNotification: Equatable {
    enum Outcome: Equatable {
        case decrypted(seq: Int64)
        case fallback(String)
    }
    var title: String
    var body: String
    var outcome: Outcome

    static func fallback(_ reason: String) -> Self {
        Self(title: "", body: Strings.pushFallbackBody, outcome: .fallback(reason))
    }

    var isFallback: Bool { if case .fallback = outcome { return true } else { return false } }
}

/// APNs 페이로드의 커스텀 키(server apns.go `pushPayload`): `room` 문자열, `seq` 정수.
struct NotificationPayload: Equatable {
    let room: RoomID
    let seq: Int64

    init?(userInfo: [AnyHashable: Any]) {
        guard let room = userInfo["room"] as? String, !room.isEmpty else { return nil }
        let seq: Int64
        switch userInfo["seq"] {
        case let value as Int64: seq = value
        case let value as Int: seq = Int64(value)
        case let value as NSNumber: seq = value.int64Value
        default: return nil
        }
        guard seq > 0 else { return nil }
        self.room = room
        self.seq = seq
    }
}

final class NotificationProcessor {
    struct Environment {
        var identity: () -> DeviceID?
        var credential: () -> RelayCredential?
        var makeTransport: (RelayCredential) -> RelayTransport?
        var engineFactory: MlsEngineFactory
        var stateStore: MlsStateStore
        var messages: MessageStore
        var outbox: OutboxStore
        var cursors: CursorStore
        /// 봇 actor(빌드 설정 `FC_AGENT_ACTORS`, 쉼표 구분) — 제목에 🤖.
        var agentActors: Set<String> = []
        var configuration: RoomSyncEngine.Configuration = NotificationProcessor.defaultConfiguration
    }

    /// NSE 예산(30 s·24 MB) 안: 락 대기 3 s(CONTRACTS §3.1 ≤5 s), 페이지 100 × 최대 5.
    static var defaultConfiguration: RoomSyncEngine.Configuration {
        var configuration = RoomSyncEngine.Configuration()
        configuration.lockTimeout = 3
        configuration.pageLimit = 100
        configuration.maxPages = 5
        configuration.decryptedBy = .nse
        return configuration
    }

    let environment: Environment

    init(_ environment: Environment) { self.environment = environment }

    /// 던지지 않는다 — 어떤 실패든 대체 알림.
    func process(_ userInfo: [AnyHashable: Any]) async -> ProcessedNotification {
        guard let payload = NotificationPayload(userInfo: userInfo) else { return .fallback("payload") }
        do {
            return try await process(payload)
        } catch StateStoreError.lockTimeout {
            return .fallback("lock_timeout")
        } catch RelayError.unauthorized {
            return .fallback("unauthorized")
        } catch RelayError.network {
            return .fallback("network")
        } catch {
            return .fallback("error: \(type(of: error))")
        }
    }

    private func process(_ payload: NotificationPayload) async throws -> ProcessedNotification {
        let env = environment
        guard let identity = env.identity(), !identity.isEmpty else { return .fallback("no_identity") }
        guard let credential = env.credential() else { return .fallback("no_credential") }
        guard let transport = env.makeTransport(credential) else { return .fallback("no_relay") }
        guard try env.messages.rooms().contains(where: { $0.room == payload.room }) else { return .fallback("unknown_room") }

        // 방 상태가 없을 때만 쓰는 시드(D2) — 앱과 같은 규칙. 방 락 안에서 identity 락을 잠깐 잡는다(앱도 같은 순서: 방 → identity).
        let store = env.stateStore
        let lockTimeout = env.configuration.lockTimeout
        let factory = SeededEngineFactory(base: env.engineFactory) {
            guard let seed = try store.withExclusive(room: Strings.identityRoom, timeout: lockTimeout, { try $0.load() }) else {
                throw StateStoreError.io("identity slot missing")
            }
            return seed
        }
        let sync = try RoomSyncEngine(room: payload.room, identity: identity, engineFactory: factory, stateStore: store,
                                      outbox: env.outbox, cursors: env.cursors, messages: env.messages, transport: transport,
                                      configuration: env.configuration)
        if let halted = sync.haltedReason { return .fallback("halted: \(halted)") }
        let passes = try await sync.syncAll()
        if let halted = passes.last?.halted ?? sync.haltedReason { return .fallback("halted: \(halted)") }
        if passes.last?.registrationPending == true { return .fallback("registration_pending") }

        guard let record = try env.messages.messages(room: payload.room, after: payload.seq - 1, limit: 1).first,
              record.seq == payload.seq else {
            return .fallback("no_message_at_seq")   // Welcome 알림·페이지 상한 너머 등
        }
        return content(for: record) ?? .fallback("undecryptable")
    }

    /// 저장된 행 → 알림 문구. 해독 불가 행은 nil(대체 알림).
    func content(for record: MessageRecord) -> ProcessedNotification? {
        let actor = record.senderActor
        let title = environment.agentActors.contains(actor) ? "🤖 \(actor)" : actor
        let body: String
        switch record.kind {
        case .text, .system:
            body = record.body.isEmpty ? Strings.pushFallbackBody : record.body
        case .attachment:
            body = Self.isImage(record.body) ? Strings.pushPhoto : Strings.pushFile
        case .undecryptable:
            return nil
        }
        return ProcessedNotification(title: title, body: body, outcome: .decrypted(seq: record.seq))
    }

    /// 첨부 표시 메타(MIME 또는 파일명)가 이미지인가.
    static func isImage(_ meta: String) -> Bool {
        let lower = meta.lowercased()
        if lower.hasPrefix("image/") { return true }
        let ext = (lower as NSString).pathExtension
        return ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp"].contains(ext)
    }

    /// `FC_AGENT_ACTORS` 값 → 집합(공백·빈 항목 무시).
    static func agentActors(from setting: String?) -> Set<String> {
        Set((setting ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

/// 한 번만 통과시키는 깃발(대체 알림과 늦게 끝난 결과가 둘 다 전달되지 않게).
final class OnceFlag {
    private let lock = NSLock()
    private var claimed = false
    /// 처음 부른 쪽만 true.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

enum NotificationDeadline {
    /// NSE 처리 기한(시스템 30 s 보다 여유 있게). `serviceExtensionTimeWillExpire` 는 별도 안전망.
    static let budget: TimeInterval = 25

    /// `work` 와 기한을 경주한다. 기한이 먼저면 대체 알림("timeout"). 작업은 취소하지 않는다(flock 대기·HTTP 는 협조적 취소가 없다).
    static func race(budget: TimeInterval = budget,
                     _ work: @escaping () async -> ProcessedNotification) async -> ProcessedNotification {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessedNotification, Never>) in
            let once = OnceFlag()
            Task.detached {
                let result = await work()
                if once.claim() { continuation.resume(returning: result) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(budget, 0) * 1_000_000_000))
                if once.claim() { continuation.resume(returning: .fallback("timeout")) }
            }
        }
    }
}
