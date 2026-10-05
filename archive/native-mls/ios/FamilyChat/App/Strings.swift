// 사용자 문구 단일 출처(web/app `strings.js` 규칙 승계). 추출·동기화는 후속(#271 §9).
import Foundation

enum Strings {
    static let appName = "패밀리챗"
    static let starting = "준비 중…"
    static let fatalTitle = "앱을 시작할 수 없습니다"
    static let decryptFormatMismatch = "암호화 모듈 버전이 맞지 않습니다(decrypt format). 앱을 업데이트해 주세요."
    static let identityRoom = "_identity"

    // 로그인
    static let loginTitle = "가족 로그인"
    static let loginHint = "Cloudflare Access 로그인 뒤 발급되는 세션으로 릴레이에 연결합니다. (뼈대: 세션 값을 직접 붙여넣기)"
    static let loginField = "세션 값"
    static let loginButton = "연결"

    // 등록
    static let enrollTitle = "이 기기 등록"
    static let enrollBody = "아래 지문과 등록 정보를 가족 운영자에게 전달하면 운영자가 기기를 체인에 올립니다. 다른 기기가 이미 있으면 그 기기에서 '신뢰 기기' 화면으로 지문을 비교해 승인합니다."
    static let fingerprintLabel = "이 기기의 지문"
    static let shareRegistration = "등록 정보 공유"
    static let enrolledButton = "등록이 끝났어요"
    static let waitingOperator = "운영자 등록 대기 중 (403 device_subject_mismatch)"

    // 방
    static let roomsTitle = "대화"
    static let noRooms = "아직 대화방이 없습니다. 운영자가 초대하면 여기 나타납니다."
    static let composerPlaceholder = "메시지"
    static let sendButton = "보내기"
    static let undecryptable = "🔒 복호화하지 못한 메시지"
    static func sendRejected(_ reason: String) -> String { "보내지 못했습니다(\(reason)). 동기화 뒤 다시 시도해 주세요." }

    // 정지
    static let haltedTitle = "⛔ 이 기기의 대화가 정지되었습니다"
    static func haltedBody(_ reason: String) -> String { "사유: \(reason). 운영자가 재등록·재초대하거나 원인을 조사할 때까지 보내기와 동기화를 멈춥니다." }

    // 설정
    static let settingsTitle = "설정"
    static let deviceIdLabel = "기기 ID"
    static let notifications = "알림"
    static let notificationsHint = "푸시는 릴레이 확장(#275)과 알림 확장(NSE) 뒤에 켜집니다."
    static let logout = "로그아웃"
    static let logoutHint = "세션만 지웁니다. 이 기기의 암호화 상태는 유지되어 다시 로그인하면 같은 기기로 이어집니다."
}
