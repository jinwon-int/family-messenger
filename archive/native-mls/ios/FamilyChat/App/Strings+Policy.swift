// 정책 링크·앱 정보(#584 PR 4, App Store 5.1.1(v)·Play 정책): 설정 화면의 「개인정보처리방침」·「계정 및 데이터 삭제」(Safari 로 연다) + 앱 버전,
// 첫 화면(서버 선택)의 안내서·개인정보처리방침 링크. 주소는 docs/hande/*.md 를 GitHub Pages 가 게시하는 정식 주소(끝 `/`, `pages.yml`).
// Android 는 BuildConfig.PRIVACY_URL/DELETE_ACCOUNT_URL(기본값 = 같은 경로) — 바꾸면 양쪽 앱·스토어 콘솔(개인정보처리방침 URL·Privacy Choices)을 함께.
// 앱 화면 전용 — NSE 소스 목록(project.yml)에 넣지 말 것.
import Foundation

enum PolicyLinks {
    /// 한데 안내(`docs/hande/index.md`) — 지원 URL·서버 운영 안내.
    static let site = URL(string: "https://jinwon-int.github.io/family-messenger/hande/")!
    /// 개인정보처리방침(`docs/hande/privacy.md`) — ASC 「Privacy Policy URL」 과 같은 주소.
    static let privacy = URL(string: "https://jinwon-int.github.io/family-messenger/hande/privacy/")!
    /// 계정 및 데이터 삭제 안내(`docs/hande/delete-account.md`) — ASC 「Privacy Choices URL」·Play 「계정 삭제 요청 URL」 과 같은 주소.
    static let deleteAccount = URL(string: "https://jinwon-int.github.io/family-messenger/hande/delete-account/")!
}

extension Strings {
    // 설정 → 정보
    static let versionLabel = "앱 버전"
    static func appVersion(_ short: String, _ build: String) -> String { "\(short) (\(build))" }

    // 설정 → 정책(라벨은 Android `Strings.privacyPolicy`/`deleteAccount` 와 같다)
    static let policySection = "정책"
    static let privacyPolicy = "개인정보처리방침"
    static let deleteAccount = "계정 및 데이터 삭제"
    static let policyHint = "개인정보처리방침은 앱과 가족 운영자의 릴레이가 무엇을 저장하고 저장하지 않는지(종단간 암호화)를, 계정 및 데이터 삭제는 서버에 남는 기기 기록 폐기·대화방 데이터 삭제를 요청하는 방법을 설명합니다. 이 기기의 자료는 아래 「이 기기 지우기」로 지웁니다."
}
