// #669 공유 확장 직접 송신(#664 과제 A, 결정 D-A1·A3·A4·A5) — 플랫폼 무관 조율.
//
// 확장은 1단계 맡김(`ShareHandoffStore.commit`)을 **먼저** 쓰고(D-A3 크래시 안전), 그 다음 이 조율기로 조각(글 → 파일 순)을
// 직접 보낸다. 실제 송신은 `ShareDirectSending` 뒤에 있다 — 확장 타깃은 NSE 와 같은 `RoomSyncEngine`(flock 단일 작성자)으로
// 구현하고, 테스트는 가짜를 준다(Foundation 만 — Linux `swift test`).
//
//   - D-A4 문턱: 직접 보내는 조각은 파일당 ≤ `maxDirectFileBytes`, 묶음 ≤ `maxDirectBatchBytes`. 첫 부적격 조각부터는 **그 뒤 전부**
//     앱에 미룬다(prefix) — 방 안의 순서가 공유한 순서와 같아야 한다(사진 10장이 뒤섞이지 않게). 상수는 여기 한 곳(P3 가 바꾼다).
//   - D-A3 표시: 조각이 처리되면 `markPiece`(sent/queued/refused). 확장이 죽어도 앱 `claim` 이 표시된 조각을 빼고 나머지만 보낸다.
//   - D-A5 분류: `.sent` 확인 · `.queued` 는 outbox 에 있으니 **맡기지 않는다**(앱 `flushOutbox` 가 같은 바이트로, #665 재료로 기록) ·
//     영구 거절(`RelayError.refused`, 413 등)은 그 조각만 refused 로 닫고 다음 조각으로 · 그 밖(참여 전·정지·등록 대기·락 대기 초과·
//     409 재시도 소진·네트워크·401·읽기 실패)은 **멈추고** 그 조각부터 앱에 맡긴다(D-A1 폴백 — ratchet 을 쓰기 전이거나 이미 reconciled
//     라 중복이 없다). 표시하지 않은 조각은 평문이 맡김에 그대로 있다.
import Foundation

/// 조각 하나를 보낸다(확장 = `RoomSyncEngine.send(text:)`/`send(fileV2:)`/`send(attachment:)`, 테스트 = 가짜).
public protocol ShareDirectSending {
    func send(_ piece: ShareHandoff.Piece) async throws -> SendOutcome
}

public enum ShareDirectSend {
    /// D-A4 초안: 파일 하나 ≤ 8 MiB(file-v2 봉인은 평문+암호문+업로드 본문 ≈ 3배 → ~25 MB, 확장 한도 안).
    public static let maxDirectFileBytes = 8 * 1024 * 1024
    /// D-A4 초안: 한 맡김에서 직접 보내는 파일 합계 ≤ 24 MiB. 실기기 측정(TestFlight, 사진 10장) 뒤 P3 에서 확정.
    public static let maxDirectBatchBytes = 24 * 1024 * 1024

    /// 어떤 조각을 확장이 직접 보내고(`direct`, 순서대로) 어떤 조각을 앱에 미루나(`deferred`).
    public struct Plan: Equatable {
        public var direct: [ShareHandoff.Piece]
        public var deferred: [ShareHandoff.Piece]
        public init(direct: [ShareHandoff.Piece] = [], deferred: [ShareHandoff.Piece] = []) {
            self.direct = direct; self.deferred = deferred
        }
    }

    /// 글은 언제나 직접. 파일은 순서대로 문턱 안이면 직접, 첫 부적격(크기 초과·묶음 초과·크기 모름)부터는 그 뒤 전부 미룬다.
    public static func plan(_ item: ShareHandoff.Item, fileSize: (String) -> Int?) -> Plan {
        var plan = Plan()
        if item.text != nil { plan.direct.append(.text) }
        var batch = 0
        var deferring = false
        for name in item.files {
            if !deferring, let bytes = fileSize(name), bytes <= maxDirectFileBytes, batch + bytes <= maxDirectBatchBytes {
                batch += bytes
                plan.direct.append(.file(name))
            } else {
                deferring = true
                plan.deferred.append(.file(name))
            }
        }
        return plan
    }

    /// 영구 거절 1건(확장 화면에 사유를 보이는 재료 — 수치는 로그에만).
    public struct Refusal: Equatable {
        public let piece: ShareHandoff.Piece
        public let status: Int
        public let code: String
    }

    public struct Report: Equatable {
        public var sent: [ShareHandoff.Piece] = []
        public var queued: [ShareHandoff.Piece] = []
        public var refused: [Refusal] = []
        /// D-A1 폴백으로 멈춘 사유(로그용, 사람에게 보이지 않는다). nil = 직접 조각을 끝까지 돌았다.
        public var stopped: String?
        /// 앱이 이어 보낼 조각(멈춘 조각부터 남은 직접 조각 + 미룬 조각). 비면 맡김을 지워도 된다(`finish`).
        public var remaining: [ShareHandoff.Piece] = []
        public init() {}

        public var needsApp: Bool { !remaining.isEmpty }
    }

    /// 계획의 직접 조각을 순서대로 보내며 표시한다. 던지지 않는다 — 어떤 실패든 Report 로.
    public static func run(plan: Plan, item id: String, store: ShareHandoffStore, sender: ShareDirectSending) async -> Report {
        var report = Report()
        var index = 0
        while index < plan.direct.count {
            let piece = plan.direct[index]
            do {
                switch try await sender.send(piece) {
                case .sent:
                    store.markPiece(id, piece, .sent)
                    report.sent.append(piece)
                case .queued:
                    store.markPiece(id, piece, .queued)
                    report.queued.append(piece)
                case .reconciled:
                    // 평문이 없는 재전송 경로의 결과라 직접 송신에서는 나오지 않는다. 나오면 바이트는 닫혔고 평문은 맡김에 있다 → 앱에.
                    report.stopped = "reconciled"
                }
            } catch RelayError.refused(let code, let status) {
                store.markPiece(id, piece, .refused)
                report.refused.append(Refusal(piece: piece, status: status, code: code))
            } catch {
                report.stopped = describe(error)
            }
            if report.stopped != nil { break }
            index += 1
        }
        report.remaining = Array(plan.direct[index...]) + plan.deferred
        return report
    }

    /// 폴백 사유 분류(로그·테스트용 짧은 토큰).
    static func describe(_ error: Error) -> String {
        switch error {
        case SyncError.notJoined: return "not_joined"
        case SyncError.halted(let reason): return "halted: \(reason)"
        case SyncError.registrationPending: return "registration_pending"
        case SyncError.casRetryExhausted: return "cas_retry_exhausted"
        case StateStoreError.lockTimeout: return "lock_timeout"
        case RelayError.unauthorized: return "unauthorized"
        case RelayError.network: return "network"
        case is ShareHandoff.Failure: return "unreadable"
        default: return "error: \(type(of: error))"
        }
    }
}
