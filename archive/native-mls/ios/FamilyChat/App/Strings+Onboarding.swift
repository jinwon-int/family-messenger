// 디자인 2차-A(2026-10-31) 온보딩 4단계·새 기기 승인·「불을 피우는 중…」 문구 — OnboardingKit·ServerSelect/ActorSetup/Login/Enroll/DevicesView 전용.
// 규칙(docs/design/HANDE-DESIGN-SYSTEM.md §A1~A3): 설명은 1줄 + 「자세히」, 성공 표시는 글자로만, 숫자 카운트다운 없음, 기술값은 화면에서 뺀다.
// 옛 문구(Strings.swift 의 actorHint·loginHint·waitingOperator 등)는 그대로 두고 여기 새 상수를 쓴다. 앱 화면 전용 — NSE 소스 목록(project.yml)에 넣지 말 것.
import Foundation
import FamilyMLSCore

extension Strings {
    // MARK: 공통(OnboardingKit)
    static let onboardingMore = "자세히"
    static let onboardingBack = "뒤로"
    static let onboardingSteps = 4
    static func onboardingStep(_ step: Int, of total: Int) -> String { "\(total)단계 중 \(step)단계" }
    /// 지문 행 VoiceOver: 「3번, 1a2b 3c4d, 맞춤 표시 안 됨」.
    static func fingerprintRowLabel(_ number: Int, _ value: String, ticked: Bool?) -> String {
        guard let ticked else { return "\(number)번, \(value)" }
        return "\(number)번, \(value), 맞춤 표시 \(ticked ? "됨" : "안 됨")"
    }

    // MARK: ① 서버 찾기
    static let serverStepTitle = "가족 서버를\n찾아 주세요"
    static let serverDeclaration = "한데에는 회원가입이 없습니다 — 가족 운영자가 등록합니다."
    static let serverAddressLabel = "서버 주소"
    static let serverAddressPlaceholder = "example.com"
    static let serverAddressHint = "운영자에게 받은 주소를 입력하세요."
    static let serverAddressDetail = "도메인(예: example.com)이나 https:// 주소. http 주소는 쓸 수 없습니다."
    static let serverFound = "찾았어요"
    /// 로그인·이름 화면 아래 한 줄: 「지금 서버 · 서윤 가족 서버」 + 「다른 서버 선택」 링크.
    static func serverCurrentLine(_ name: String) -> String { "지금 서버 · \(name)" }

    // MARK: ② 이름
    static let actorStepTitle = "이 기기를 쓰는 분의\n이름"
    static let actorStepLabel = "운영자가 정해 준 영문 이름"
    static let actorStepPlaceholder = "영문 이름"
    static let actorStepHint = "한 번 정하면 바꿀 수 없어요."
    static let actorStepDetail = "영문 소문자로 시작, 소문자·숫자 2~16자(예: mom, dad, jiyu). 이 기기 ID가 이 이름으로 만들어집니다. 바꾸려면 앱을 지우고 새 기기로 다시 등록합니다."
    /// 형식 오류 — 모델 값은 `Strings.actorInvalid` 그대로, 화면에는 이 한 줄.
    static let actorStepInvalid = "영문 소문자·숫자 2~16자로 써 주세요"

    // MARK: ③ Google 로그인
    static let loginStepLine = "운영자가 허용해 둔 Google 계정으로 들어갑니다."
    static let loginStepDetail = "로그인 창은 Safari가 열고, 비밀번호는 앱에 전달되지 않습니다. 끝나면 자동으로 돌아옵니다."

    // MARK: ④ 이 기기 등록
    static let enrollStepLine = "이미 쓰는 내 기기나 운영자가 이 지문을 보고 승인합니다."
    static let enrollWaitingOperator = "운영자 승인을 기다리는 중"
    static let enrollWaitingSibling = "다른 기기의 승인을 기다리는 중"
    static func enrollWaitingSiblingUntil(_ at: Date) -> String { "\(enrollWaitingSibling) · \(clockLabel(at))까지" }
    /// 옛 대기 문구의 기술값 — 화면에는 내지 않는다(진단 기록 몫).
    static let enrollDiagnosticToken = "403 device_subject_mismatch"
    /// 키 생성 중(용어표: 키 생성 중 = 불을 피우는 중…).
    static let kindlingTitle = "불을 피우는 중…"
    static let kindlingBody = "암호 키를 만들고 있어요"

    // MARK: 새 기기 승인(2a) — 후보 카드 · CandidateApprovalView
    static let candidateIncoming = "새 기기가 들어오려고 합니다"
    /// 「요청 21:10 · 21:40에 만료」 — 시각만, 카운트다운 없음.
    static func candidateTimes(created: Date, expires: Date) -> String { "요청 \(clockLabel(created)) · \(clockLabel(expires))에 만료" }
    static let approveCompareTitle = "새 기기 화면과 하나씩 맞춰 보세요"
    static func approveProgress(_ ticked: Int, of total: Int) -> String { "같으면 눌러 표시하세요 · \(ticked) / \(total)" }
    static let approveAllMatched = "모두 맞췄어요"
    static let approveWarning = "지문이 다르면 승인하지 말고 운영자에게 알려 주세요."
    static let approveButton = "승인"
    static func approveDisabled(_ total: Int) -> String { "\(total)줄을 모두 맞춰 보세요" }
    static func approveDisabledAccessibility(_ total: Int) -> String { "\(total)줄을 모두 맞춘 뒤 승인할 수 있습니다" }
    static let approveMismatchButton = "다릅니다"
    static let approveLaterButton = "나중에"
    static func approvedTitle(_ device: String) -> String { "\(device)를 승인했어요" }
    static let approvedBody = "이 기기가 있는 자리에 자동으로 초대합니다."
    static let approveConfirmButton = "확인"
    static let rejectedTitle = "승인하지 않았어요"
    static func rejectedBody(_ device: String) -> String { "\(device)는 들어오지 못합니다. 운영자에게 지문이 달랐다고 알려 주세요." }
    static let copyDiagnosticsButton = "진단 기록 복사"

    /// 한국 24시간 「HH:mm」.
    static func clockLabel(_ at: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "HH:mm"
        return f.string(from: at)
    }
}
