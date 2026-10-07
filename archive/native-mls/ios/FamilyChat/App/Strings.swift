// 사용자 문구 단일 출처(web/app `strings.js` 규칙 승계). 추출·동기화는 후속(#271 §9).
import Foundation

enum Strings {
    static let appName = "패밀리챗"
    static let starting = "준비 중…"
    static let fatalTitle = "앱을 시작할 수 없습니다"
    static let decryptFormatMismatch = "암호화 모듈 버전이 맞지 않습니다(decrypt format). 앱을 업데이트해 주세요."
    static let identityRoom = "_identity"
    static let relayNotConfigured = "릴레이 주소가 설정되지 않았습니다(빌드 설정 FC_RELAY_URL)."
    static let sessionExpired = "로그인 세션이 만료되었습니다. 다시 로그인해 주세요."
    static func storageUnavailable(_ detail: String) -> String { "기기 저장소를 열 수 없습니다: \(detail)" }

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
    static let enrolledButton = "등록 확인"
    static let waitingOperator = "운영자 등록 대기 중 (403 device_subject_mismatch)"

    // 방
    static let roomsTitle = "대화"
    static let noRooms = "아직 대화방이 없습니다. 운영자가 초대하면 여기 나타납니다."
    static let composerPlaceholder = "메시지"
    static let sendButton = "보내기"
    static let undecryptable = "🔒 복호화하지 못한 메시지"
    static func sendRejected(_ reason: String) -> String { "보내지 못했습니다(\(reason)). 동기화 뒤 다시 시도해 주세요." }
    static let sendQueued = "릴레이에 닿지 않아 보관했습니다. 연결되면 같은 내용 그대로 다시 보냅니다."
    static let notJoined = "아직 이 대화방에 참여하지 않았습니다. 초대를 기다려 주세요."

    // 정지
    static let haltedTitle = "⛔ 이 기기의 대화가 정지되었습니다"
    static func haltedBody(_ reason: String) -> String { "사유: \(reason). 운영자가 재등록·재초대하거나 원인을 조사할 때까지 보내기와 동기화를 멈춥니다." }

    // 설정
    static let settingsTitle = "설정"
    static let deviceIdLabel = "기기 ID"
    static let notifications = "알림"
    static let notificationsHint = "새 메시지 알림은 이 기기가 등록된 뒤 켜집니다. 알림에는 릴레이가 내용을 싣지 않고, 기기가 받아서 직접 복호화합니다."
    static let pushOff = "꺼짐"
    static let pushWaiting = "알림 토큰 대기 중"
    static let pushRegistered = "켜짐"
    static let pushNoTopic = "이 빌드에는 푸시 설정(FC_PUSH_TOPIC)이 없습니다"
    static let pushDenied = "알림 권한이 꺼져 있습니다(설정 앱에서 켤 수 있습니다)"
    static let pushNetwork = "릴레이에 닿지 않음"
    static func pushFailed(_ reason: String) -> String { "등록 실패: \(reason) — 잠시 뒤 다시 시도합니다" }
    static let logout = "로그아웃"
    static let logoutHint = "세션만 지웁니다. 이 기기의 암호화 상태는 유지되어 다시 로그인하면 같은 기기로 이어집니다."

    // 알림 확장(NSE, §12-D) — 대체 문구는 앱 번들 `ko.lproj/Localizable.strings` 의 `NEW_MESSAGE` 와 같아야 한다
    // (NSE 가 죽거나 시간을 넘기면 iOS 가 원래 alert 의 loc-key 를 그 파일로 푼다).
    static let pushFallbackBody = "새 메시지가 도착했습니다"
    static let pushPhoto = "「사진」"
    static let pushFile = "「파일」"
}
