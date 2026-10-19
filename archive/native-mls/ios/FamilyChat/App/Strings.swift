// 사용자 문구 단일 출처(web/app `strings.js` 규칙 승계). 추출·동기화는 후속(#271 §9).
import Foundation

enum Strings {
    static let appName = "한데"
    static let starting = "준비 중…"
    static let fatalTitle = "앱을 시작할 수 없습니다"
    static let decryptFormatMismatch = "암호화 모듈 버전이 맞지 않습니다(decrypt format). 앱을 업데이트해 주세요."
    static let identityRoom = "_identity"
    static let relayNotConfigured = "릴레이 주소가 설정되지 않았습니다(빌드 설정 FC_RELAY_URL)."
    static let sessionExpired = "로그인 세션이 만료되었습니다. 다시 로그인해 주세요."
    static func storageUnavailable(_ detail: String) -> String { "기기 저장소를 열 수 없습니다: \(detail)" }

    // 사용자 이름(actor) — 첫 실행 1회
    static let actorTitle = "이 기기 사용자"
    static let actorField = "이름(영문 소문자)"
    static let actorHint = "가족 운영자가 정해 준 영문 이름을 입력하세요(예: mom, dad, jiyu). 소문자로 시작하는 영문 소문자·숫자 2~16자. 이 기기의 ID가 이 이름으로 만들어지며, 한 번 정하면 바꿀 수 없습니다(바꾸려면 앱을 지우고 새 기기로 다시 등록)."
    static let actorButton = "확인"
    static let actorInvalid = "이름 형식이 맞지 않습니다 — 소문자로 시작하는 영문 소문자·숫자 2~16자(하이픈·공백 불가)."

    // 로그인(§12-C A, LoginView · AppLogin.swift)
    static let loginTitle = "가족 로그인"
    static let loginGoogle = "Google 계정으로 로그인"
    static let loginHint = "가족 운영자가 허용한 Google 계정으로 로그인합니다. 로그인 창은 iPhone 의 Safari 가 열고, 비밀번호는 앱에 전달되지 않습니다. 로그인이 끝나면 이 앱으로 자동으로 돌아옵니다."
    static func loginFailed(_ reason: String) -> String { "로그인하지 못했습니다: \(reason)" }
    static let loginManualTitle = "직접 입력(운영자용)"
    static let loginManualHint = "PC 브라우저의 세션 값(CF_Authorization)을 붙여넣는 운영자용 방법입니다. 가족은 위의 로그인 버튼을 쓰세요."
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
    static let noRooms = "아직 대화방이 없습니다. 오른쪽 위 + 로 참여를 요청하고, 운영자가 초대하면 여기 나타납니다."
    static let composerPlaceholder = "메시지"
    static let sendButton = "보내기"
    static let undecryptable = "🔒 복호화하지 못한 메시지"
    static func sendRejected(_ reason: String) -> String { "보내지 못했습니다(\(reason)). 동기화 뒤 다시 시도해 주세요." }
    /// 방 화면 제목 아래: 릴레이에 닿지 않는 동안(`AppModel.reconnecting`).
    static let connecting = "연결 중입니다…"
    /// 보내는 글(오너 요청 build 31: 누르는 즉시 목록에 올리고, 상태는 말풍선 아래에).
    static let outgoingSending = "보내는 중…"
    static let outgoingQueued = "연결되면 보냅니다"
    static let outgoingFailed = "전송 안 됨"
    static let outgoingRetry = "다시 보내기"
    static let outgoingAttachment = "사진·파일 보내는 중"
    static let sendQueued = "릴레이에 닿지 않아 보관했습니다. 연결되면 같은 내용 그대로 다시 보냅니다."
    static let notReady = "아직 준비되지 않았습니다. 잠시 뒤 다시 보내 주세요."
    static let notJoined = "아직 이 대화방에 참여하지 않았습니다. 초대를 기다려 주세요."
    /// 첨부 한도(AttachmentFormat.maxBytes) 초과 — AppModel 이 쓰므로 여기(NSE 공유 파일)에 둔다.
    static func attachmentTooLarge(_ bytes: Int) -> String {
        "첨부는 5 MiB(5,242,880바이트) 이하여야 합니다(지금 \(bytes.formatted())바이트). 사진은 자동으로 줄이지만 파일은 줄일 수 없습니다."
    }

    // 참여 요청(JoinRequestView, §12-E) — 기본 대화방 ID 는 빌드 설정 FC_DEFAULT_ROOM(AppModel.defaultRoom)
    static let joinTitle = "대화방 참여 요청"
    static let joinField = "대화방 ID"
    static let joinButton = "참여 요청"
    static let joinHint = "운영자가 알려준 대화방 ID를 그대로 입력하세요(가족 대화방은 보통 family). 이 기기의 키 패키지(공개 정보)를 그 대화방에 게시합니다. 운영자가 다른 기기의 '초대'로 받아들이면 대화가 시작됩니다. 메시지나 비밀키는 보내지 않습니다."
    static let joinRequested = "참여를 요청했습니다. 운영자의 초대를 기다려 주세요."
    static func joinFailed(_ reason: String) -> String { "참여 요청에 실패했습니다: \(reason)" }
    static let close = "닫기"
    static let roomActions = "대화방"

    // 방 만들기(CreateRoomView, §12-E)
    static let createTitle = "대화방 만들기"
    static let createHint = "이 기기에서 새 대화방을 만듭니다(영문 소문자·숫자·하이픈, 최대 48자). 릴레이에는 첫 초대 때 생깁니다 — 만든 뒤 방에 들어가 '초대'로 다른 기기를 들이세요."
    static let createButton = "만들기"
    static let createDone = "대화방을 만들었습니다. 방에 들어가 '초대'로 다른 기기를 들이세요."
    static let roomIdInvalid = "대화방 ID 형식이 맞지 않습니다 — 영문 소문자·숫자로 시작, 소문자·숫자·하이픈 최대 48자."

    // 초대(InviteView, §12-E)
    static let inviteTitle = "기기 초대"
    static let inviteField = "초대할 기기 ID"
    static let inviteHint = "상대 기기의 '설정 → 기기 ID'(예: mom-iphone-1a2b3c)를 입력하세요. 상대가 먼저 이 대화방에 '참여 요청'을 해 두었거나, 상대 앱이 로비 키를 올려 두었어야 합니다(앱을 한 번 열면 됩니다). 초대하면 이 방의 암호화 키가 바뀌고(새 epoch) 상대가 대화에 들어옵니다."
    static let inviteButton = "초대"
    static func inviteDone(_ device: String) -> String { "\(device) 기기를 초대했습니다. 상대 앱에서 목록을 새로고침하면 대화가 열립니다." }
    static let inviteSelf = "자기 자신은 초대할 수 없습니다."
    static let deviceIdInvalid = "기기 ID 형식이 맞지 않습니다(영문·숫자·하이픈·밑줄, 최대 64자)."

    // 정지
    static let haltedTitle = "⛔ 이 기기의 대화가 정지되었습니다"

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

    // 로비 키(#380 P5-3) — AppModel 이 쓰므로 여기(NSE 공유 파일)에 둔다
    static let lobbyKeysLabel = "로비 키"
    static func lobbyKeys(_ live: Int?) -> String { live.map { "\($0)개" } ?? "확인 전" }
    static let lobbyHint = "로비 키는 이 기기의 공개 키 패키지입니다. 운영자가 steward 봇에게 지시하면 이 키로 탭 없이 새 대화방에 초대됩니다(오너 기기는 자동 가입, 가족 기기는 수락 1탭). 앱을 열 때마다 모자란 만큼 채웁니다."
    static func lobbyJoined(_ room: String) -> String { "새 대화방 「\(room)」에 들어왔습니다." }
    static let inviteSectionTitle = "새 대화방 초대"
    static func inviteBody(_ room: String) -> String { "운영자가 「\(room)」 대화방에 이 기기를 초대했습니다. 수락하면 대화에 들어갑니다." }
    static let acceptInvite = "수락"
    static let ignoreInvite = "무시"
    static func inviteAcceptFailed(_ reason: String) -> String { "초대를 받아들이지 못했습니다: \(reason)" }

    // 알림 확장(NSE, §12-D) — 대체 문구는 앱 번들 `ko.lproj/Localizable.strings` 의 `NEW_MESSAGE` 와 같아야 한다
    // (NSE 가 죽거나 시간을 넘기면 iOS 가 원래 alert 의 loc-key 를 그 파일로 푼다).
    static let pushFallbackBody = "새 메시지가 도착했습니다"
    static let pushPhoto = "「사진」"
    static let pushFile = "「파일」"
}
