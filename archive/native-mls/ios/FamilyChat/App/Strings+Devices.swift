// 새 기기 셀프서비스(#574 PR 3) 화면 문구 — 등록 화면 모드·새 기기 승인 시트·「내 기기」. 앱 화면 전용 — NSE 소스 목록(project.yml)에 넣지 말 것.
// 웹 `web/hande/strings.js` 의 `enroll`·`candidates`·`devices`·`approve` 와 같은 뜻.
import Foundation
import FamilyMLSCore

extension Strings {
    // 등록 화면(EnrollView) — 모드별 안내(AppModel.enrollment)
    static let enrollSiblingTitle = "다른 기기에서 승인해 주세요"
    static let enrollSiblingBody = "이 기기의 등록 요청을 릴레이에 올렸습니다. 이미 쓰고 있는 내 기기(같은 계정)의 한데를 열고 🔔 알림 → 「새 기기 승인」에서 아래 지문이 같은지 한 자리씩 비교한 뒤 승인하세요. 승인되면 그 기기가 참여한 대화방에 자동으로 초대됩니다."
    static func enrollSiblingExpires(_ at: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "HH:mm"
        return "요청은 \(f.string(from: at))까지 유효하며 그 전에 자동으로 다시 올립니다."
    }
    static let enrollIdTakenTitle = "이 기기 ID 는 다시 쓸 수 없습니다"
    static let enrollIdTakenBody = "이 기기 ID 가 이미 체인에 있습니다(지운 기기의 ID 는 재사용하지 않습니다). 「이 기기 지우기」로 새 ID 를 만든 뒤 다시 등록하세요."
    static let enrollOperatorBody = "운영자에게 지문과 등록 정보를 전달하면 운영자가 기기를 체인에 올립니다. 이 계정에 활성 기기가 하나라도 있으면 그 기기의 한데에서 직접 승인할 수도 있습니다(릴레이가 지원할 때)."

    // 새 기기 승인(NotificationsView 칸 · CandidateApprovalView)
    static let candidatesSectionTitle = "새 기기 승인"
    static func candidateBody(_ device: String) -> String { "같은 계정의 새 기기 「\(device)」가 승인을 기다립니다. 그 기기 화면의 지문과 아래 지문이 같은지 확인하세요." }
    static let candidateApproveButton = "지문 비교"
    static let candidateIgnoreButton = "무시"
    static let candidateFingerprintLabel = "새 기기의 지문"
    static let candidateConfirmButton = "이 지문이 맞습니다"
    static let candidateConfirmHint = "이 기기의 서명키로 승인 증거를 만들어 릴레이에 올립니다. 지문이 한 자리라도 다르면 승인하지 마세요 — 다른 사람의 기기일 수 있습니다."
    static let candidateMismatch = "릴레이가 전한 지문이 공개키에서 계산한 값과 다릅니다 — 승인하지 않습니다."
    static func candidateExpires(_ at: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "HH:mm"
        return "요청 유효 시한 \(f.string(from: at))"
    }
    static let candidateApproving = "승인하는 중…"
    static func candidateDone(_ device: String) -> String { "\(device) 기기를 승인했습니다." }

    // 「내 기기」(DevicesView)
    static let devicesTitle = "내 기기"
    static let devicesHint = "이 계정으로 등록된 기기 전부(폐기 포함)입니다. 「등록 기기」(registrar)는 새 기기를 승인할 수 있는 기기입니다 — 등록 기기가 하나라도 있으면 그 기기만 승인할 수 있고, 마지막 등록 기기는 해제할 수 없습니다(다른 기기에 먼저 부여)."
    static let devicesEmpty = "기기 목록을 아직 받지 못했습니다(옛 릴레이거나 로그인 전)."
    static let devicesUnknownRelay = "이 릴레이는 기기 목록을 주지 않습니다(기기 저장소 없음)."
    static let registrarPill = "등록 기기"
    static let thisDevicePill = "이 기기"
    static let revokedPill = "폐기됨"
    static let grantRegistrar = "등록 기기로 지정"
    static let releaseRegistrar = "등록 기기 해제"
    static let lastRegistrarHint = "마지막 등록 기기 — 다른 기기에 먼저 부여해야 해제할 수 있습니다."
    static let rolesBusy = "바꾸는 중…"
    static func rolesDone(_ device: String, grant: Bool) -> String { grant ? "\(device) 기기를 등록 기기로 지정했습니다." : "\(device) 기기의 등록 기기 역할을 해제했습니다." }

    // 🔔 알림의 형제 기기 초대 결과(AppModel.siblingNotes)
    static let siblingNotesTitle = "새 기기 초대"
    static let dismissNote = "지움"

    /// 승인·역할 실패를 사람이 읽을 문구로.
    static func selfServiceFailure(_ error: Error) -> String {
        switch error {
        case let refusal as DevicePolicyRefusal:
            if refusal.code == RelayErrorCode.staleRevision.rawValue { return "체인이 그사이 바뀌었습니다. 잠시 뒤 다시 시도하세요." }
            return "릴레이가 거부했습니다: \(refusal.detail ?? refusal.code)"
        case AppModel.SelfServiceError.fingerprintMismatch: return candidateMismatch
        case AppModel.SelfServiceError.baseRevisionUnknown: return "정책 revision 을 모릅니다(옛 릴레이거나 /v2/me 실패). 잠시 뒤 다시 시도하세요."
        case AppModel.SelfServiceError.unknownCandidate: return "그 요청은 이미 처리됐거나 만료됐습니다."
        case AppModel.SelfServiceError.unknownDevice: return "그 기기는 이 계정의 목록에 없습니다."
        case AppModel.SelfServiceError.notReady: return notReady
        case RelayError.unauthorized: return sessionExpired
        case RelayError.refused(let code, _): return "릴레이가 거부했습니다(\(code))."
        case RelayError.network: return "릴레이에 닿지 않습니다. 연결을 확인하고 다시 시도하세요."
        case EngineError.rejected(let reason): return "서명하지 못했습니다(\(reason))."
        default: return "\(error)"
        }
    }
}
