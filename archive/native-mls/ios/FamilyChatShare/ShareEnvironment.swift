// 한데 공유 확장(#643 1단계)의 운영 조립 — 알림 확장(`NSEEnvironment`)과 같은 규칙으로 서버·스코프를 정한다:
// App Group `hande.server`(앱이 적은 선택) → 빌드 기본값 `FamilyChatRelayURL`(`ServerStore.resolve`), 스코프 = `ServerScope(baseURL:)`.
// 확장은 MLS 상태·Keychain·FFI 를 열지 않는다(결정 D1) — 맡김 디렉터리와 앱이 써 둔 공유 대상 목록(`ShareHandoff.targetsKey`)만 본다.
// 그래서 `SharedStorage`(Keychain·봉인 키)를 링크하지 않고 App Group 컨테이너·defaults 를 여기서 직접 연다(같은 API, 같은 키).
import Foundation
import FamilyMLSCore

struct ShareEnvironment {
    let store: ShareHandoffStore
    /// 맡김에 적는 서버 스코프 ID — 앱은 지금 스코프의 맡김만 보낸다.
    let scope: String
    /// 앱이 써 둔 공유할 수 있는 방(목록 화면 순서). 비면 앱을 한 번도 열지 않았거나 로그인 전.
    let targets: [RoomID]

    static func live(bundle: Bundle = .main) -> ShareEnvironment? {
        func value(_ key: String) -> String? {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        // App Group 이 없으면(무서명 CI·시뮬레이터) 앱과 나눌 자리가 없다 — 화면이 「앱을 먼저 열어」 안내를 보인다.
        guard let group = value("FamilyChatAppGroup"),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              let shared = UserDefaults(suiteName: group) else { return nil }
        let defaultURL = value("FamilyChatRelayURL").flatMap(URL.init(string:))
        guard let server = ServerStore.resolve(DefaultsServerStore(defaults: shared).load(), defaultURL: defaultURL) else { return nil }
        let scope = ServerScope(baseURL: server.baseURL)
        let targets = scope.defaults(shared).stringArray(forKey: ShareHandoff.targetsKey) ?? []
        return ShareEnvironment(store: ShareHandoffStore(container: container), scope: scope.id, targets: targets)
    }
}
