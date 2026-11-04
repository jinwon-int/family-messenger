// 한데 공유 확장의 운영 조립 — 알림 확장(`NSEEnvironment`)과 같은 규칙으로 서버·스코프를 정한다:
// App Group `hande.server`(앱이 적은 선택) → 빌드 기본값 `FamilyChatRelayURL`(`ServerStore.resolve`), 스코프 = `ServerScope(baseURL:)`.
// 1단계(#643): 맡김 디렉터리와 앱이 써 둔 공유 대상 목록(`ShareHandoff.targetsKey`)만 본다 — `store`·`targets`.
// 2단계(#669, #664 과제 A): 그 위에 NSE 와 같은 방식으로 MLS 상태·Keychain·FFI 를 열어 직접 보낸다 — `direct`. 열 수 없으면(App Group 없음·
// 로그인 전·기기 ID 없음·스코프 미생성) nil 이고 확장은 1단계처럼 맡기기만 한다(D-A1 폴백).
import Foundation
import FamilyMLSCore

struct ShareEnvironment {
    let store: ShareHandoffStore
    /// 맡김에 적는 서버 스코프 ID — 앱은 지금 스코프의 맡김만 보낸다.
    let scope: String
    /// 앱이 써 둔 공유할 수 있는 방(목록 화면 순서). 비면 앱을 한 번도 열지 않았거나 로그인 전.
    let targets: [RoomID]
    /// #669 직접 송신 조립. nil = 맡기기만.
    let direct: ShareDirectEnvironment?

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
        return ShareEnvironment(store: ShareHandoffStore(container: container), scope: scope.id, targets: targets,
                                direct: ShareDirectEnvironment.live(group: group, container: container, server: server))
    }
}
