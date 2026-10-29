// 선택한 서버(#584 PR 2) — App Group UserDefaults `hande.server` 에 JSON 으로. 앱·NSE 가 같은 값을 읽는다(NSE 는 읽기만).
//
// 해석 규칙(`ServerStore.resolve`, 순수 — NSE 와 앱이 같은 함수):
//   선택값 있음 → 그 서버 · 사용자가 「서버 바꾸기」로 비움(`cleared`) → 없음(앱은 서버 선택 화면) ·
//   아무것도 없음 → 빌드 설정 `FC_RELAY_URL`(Info.plist `FamilyChatRelayURL`, 가족 TestFlight 기본값) → 그것도 없으면 없음(App Store 빌드).
// NSE 소스 목록(project.yml)에 들어간다 — UIKit·SwiftUI 의존 금지.
import Foundation
import FamilyMLSCore

/// 저장되는 값: 주소·이름·찾은 방법·선택 시각. 비밀 아님.
struct ServerSelection: Codable, Equatable {
    var baseURL: URL
    var name: String?
    var discoveredVia: ServerInfo.Via
    var selectedAt: Date

    init(baseURL: URL, name: String? = nil, discoveredVia: ServerInfo.Via, selectedAt: Date) {
        self.baseURL = baseURL
        self.name = name
        self.discoveredVia = discoveredVia
        self.selectedAt = selectedAt
    }

    init(info: ServerInfo, at date: Date) {
        self.init(baseURL: info.baseURL, name: info.name, discoveredVia: info.discoveredVia, selectedAt: date)
    }

    /// 빌드 설정 기본값(탐색 없이 채택, 이름 없음).
    init(defaultURL: URL, at date: Date = Date()) {
        self.init(baseURL: defaultURL, name: nil, discoveredVia: .buildDefault, selectedAt: date)
    }

    /// 테스트 기본값(`AppModel.Dependencies.server`) — 서버 선택 화면을 건너뛴다. 실제 주소 아님.
    static let testing = ServerSelection(baseURL: URL(string: "https://relay.test")!, name: "테스트", discoveredVia: .direct,
                                         selectedAt: Date(timeIntervalSince1970: 0))

    /// 화면 표시용 호스트(이름이 없을 때).
    var displayName: String { name ?? baseURL.host ?? baseURL.absoluteString }
}

enum ServerStore {
    static let key = "hande.server"
    /// 「서버 바꾸기」로 비운 상태 — 다음 실행에 빌드 기본값으로 되돌아가지 않게.
    static let clearedKey = "hande.server.cleared"

    enum State: Equatable {
        /// 아무것도 적힌 적 없음(첫 실행·옛 설치) → 빌드 기본값.
        case unset
        case cleared
        case selected(ServerSelection)
    }

    static func encode(_ selection: ServerSelection) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(selection)
    }

    static func decode(_ data: Data) -> ServerSelection? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ServerSelection.self, from: data)
    }

    /// 저장 상태 + 빌드 기본값 → 실제 쓸 서버(nil = 서버 선택 화면).
    static func resolve(_ state: State, defaultURL: URL?, now: Date = Date()) -> ServerSelection? {
        switch state {
        case .selected(let selection): return selection
        case .cleared: return nil
        case .unset: return defaultURL.map { ServerSelection(defaultURL: $0, at: now) }
        }
    }
}

protocol ServerStoring: AnyObject {
    func load() -> ServerStore.State
    func save(_ selection: ServerSelection)
    func clear()
}

final class InMemoryServerStore: ServerStoring {
    private var state: ServerStore.State
    init(_ state: ServerStore.State = .unset) { self.state = state }
    func load() -> ServerStore.State { state }
    func save(_ selection: ServerSelection) { state = .selected(selection) }
    func clear() { state = .cleared }
}

/// App Group UserDefaults(`SharedStorage.defaults`) — 스코프 밖(서버를 고르기 전이라 스코프가 없다).
final class DefaultsServerStore: ServerStoring {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> ServerStore.State {
        if let data = defaults.data(forKey: ServerStore.key), let selection = ServerStore.decode(data) { return .selected(selection) }
        if defaults.bool(forKey: ServerStore.clearedKey) { return .cleared }
        return .unset
    }

    func save(_ selection: ServerSelection) {
        guard let data = try? ServerStore.encode(selection) else { return }
        defaults.set(data, forKey: ServerStore.key)
        defaults.removeObject(forKey: ServerStore.clearedKey)
    }

    func clear() {
        defaults.removeObject(forKey: ServerStore.key)
        defaults.set(true, forKey: ServerStore.clearedKey)
    }
}
