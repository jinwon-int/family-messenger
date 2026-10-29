// 서버 선택(#584 PR 2) 화면 문구 — 첫 화면(ServerSelectView)·설정 「서버」. 앱 화면 전용 — NSE 소스 목록(project.yml)에 넣지 말 것.
// AppModel 이 쓰는 탐색 실패 문구(`serverDiscoveryFailure`)는 Strings.swift(NSE·Linux 스모크 공유 파일).
import Foundation
import FamilyMLSCore

extension Strings {
    // 첫 화면 상단 안내(#584 PR 4, 가이드라인 4.2 대비): 서버 주소가 없는 사람(심사관 포함)도 이 앱이 무엇인지 알게 한다 —
    // Element 홈서버 선택 화면과 같은 구성. 안내서 링크는 PolicyLinks.site(docs/hande 게시 주소).
    static let serverIntroTitle = "한데는 가족 운영자의 서버에 연결하는 종단간 암호화 메신저입니다"
    static let serverIntro = "공개 가입이 없습니다. 가족 중 한 사람(운영자)이 직접 세운 서버에 연결해 쓰고, 메시지는 기기에서만 풀리는 종단간 암호화(MLS)로 보호되어 서버 운영자도 읽을 수 없습니다. 운영자에게 서버 도메인(예: example.com)을 받아 아래에 입력하세요. 서버를 직접 운영하려면 안내서를 보세요."
    static let serverHelp = "한데 안내서·서버 운영 방법"

    // 첫 화면(ServerSelectView)
    static let serverTitle = "서버 선택"
    static let serverField = "서버 주소(도메인 또는 https 주소)"
    static let serverHint = "가족 운영자가 알려준 서버 도메인(예: example.com)을 입력하세요. 앱이 그 도메인의 .well-known/hande 에서 릴레이 주소를 찾고, 없으면 입력한 주소를 릴레이로 씁니다(/v2/health 확인). 웹 설정 화면의 hande://server?url=… 링크를 붙여넣거나 열어도 됩니다. 암호화되지 않은 http 주소는 쓸 수 없습니다."
    static let serverFind = "서버 찾기"
    static let serverSearching = "서버를 찾는 중…"
    static let serverFoundTitle = "찾은 서버"
    static let serverNameLabel = "이름"
    static let serverURLLabel = "릴레이 주소"
    static let serverNoName = "(이름 없음)"
    static func serverVia(_ via: ServerInfo.Via) -> String {
        switch via {
        case .wellKnown: return ".well-known/hande 로 찾았습니다"
        case .direct: return "입력한 주소를 릴레이로 씁니다(/v2/health 확인)"
        case .buildDefault: return "이 빌드의 기본 서버"
        }
    }
    static let serverContinue = "이 서버로 계속"

    // 설정 → 서버 · 로그인/이름 화면의 「다른 서버 선택」
    static let serverSection = "서버"
    static let serverChange = "서버 바꾸기"
    static let serverChangeWarning = "로그아웃하고 서버 선택 화면으로 돌아갑니다. 이 기기의 이 서버 데이터(기기 ID·암호화 상태·대화)는 지우지 않고 서버별로 따로 보관하므로, 같은 서버를 다시 고르면 그대로 이어집니다. 새 서버에서는 새 기기로 시작합니다."
    static let serverChangeConfirm = "서버 바꾸기"
    static let serverOther = "다른 서버 선택"
}
