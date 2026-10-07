// `AppModel.Dependencies.live()` — 실제 구현 조립(파이널라이저 통합, #271).
//
//  - 엔진: ios-ffi xcframework `FfiEngineFactory`(방 상태 시드는 AppModel 의 `SeededEngineFactory`, 결정 D2)
//  - MLS 상태: L1 `FileStateStore`(`<base>/mls/<room>.state`, flock 단일 작성자, 원자 영속,
//    봉인 = CryptoKit ChaChaPoly + Keychain 32B 키 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
//  - 메시지·outbox·커서: L1 `FileSQLiteStore`(`<base>/messages.db`, 한 DB)
//  - 릴레이: L3 `URLSessionRelayTransport`(주소 = Info.plist `FamilyChatRelayURL`, 빌드 설정 `FC_RELAY_URL`)
//
// `<base>` = Info.plist `FamilyChatAppGroup`(빌드 설정 `FC_APP_GROUP`)의 App Group 컨테이너. NSE(§12-D)가 같은 상태를
// 열려면 App Group 이 필요하다. 설정이 비었거나 컨테이너를 못 얻으면(무서명 시뮬레이터·CI) 앱 전용 Application Support 로
// 폴백한다 — 이때는 NSE 와 공유되지 않는다. 저장소를 열지 못하면 `startupFailure` 로 fatal 화면에 사유를 보인다.
// 실제 호스트명·Bundle ID·Team ID 는 리포에 두지 않는다(CONTRIBUTING) — 빌드 설정으로 주입.
import Foundation
import FamilyMLSCore

extension AppModel.Dependencies {
    struct LiveConfiguration {
        var relayURL: URL?
        var appGroup: String?
        /// 테스트가 임시 디렉터리를 줄 때만 쓴다. nil = App Group 또는 Application Support.
        var baseDirectory: URL?
        /// nil = 플랫폼 기본 봉인(ChaChaPoly + Keychain). 테스트는 정적 키 봉인을 준다.
        var sealer: FileStateSealing?
        var identityProvider: () -> DeviceID = { DeviceIdentity.stableDeviceId(actor: "owner") }

        static func fromBundle(_ bundle: Bundle = .main) -> Self {
            func value(_ key: String) -> String? {
                guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return Self(relayURL: value("FamilyChatRelayURL").flatMap(URL.init(string:)), appGroup: value("FamilyChatAppGroup"))
        }
    }

    static func live() -> Self { live(.fromBundle()) }

    static func live(_ config: LiveConfiguration) -> Self {
        let makeTransport: (RelayCredential) -> RelayTransport? = { credential in
            config.relayURL.map { URLSessionRelayTransport(baseURL: $0, credential: credential) }
        }
        do {
            let base = try storageDirectory(config)
            let stateStore = try FileStateStore(directory: base.appendingPathComponent("mls", isDirectory: true), sealer: config.sealer)
            let database = try FileSQLiteStore(directory: base)
            return Self(
                engineFactory: FfiEngineFactory(),
                stateStore: stateStore,
                messageStore: database,
                outbox: database,
                cursors: database,
                identityProvider: config.identityProvider,
                expectedDecryptFormat: { FfiEngineFactory.reportedDecryptFormat() },
                makeTransport: makeTransport)
        } catch {
            // 화면이 사유를 보여 줄 수 있게 메모리 스토어로 모델만 세운다(아무것도 저장하지 않는다).
            return Self(
                engineFactory: FfiEngineFactory(),
                stateStore: InMemoryStateStore(),
                messageStore: InMemoryMessageStore(),
                outbox: InMemoryOutboxStore(),
                cursors: InMemoryCursorStore(),
                identityProvider: config.identityProvider,
                expectedDecryptFormat: { FfiEngineFactory.reportedDecryptFormat() },
                makeTransport: makeTransport,
                startupFailure: Strings.storageUnavailable("\(error)"))
        }
    }

    static func storageDirectory(_ config: LiveConfiguration) throws -> URL {
        if let base = config.baseDirectory { return base }
        if let group = config.appGroup,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return container
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("FamilyChat", isDirectory: true)
    }
}
