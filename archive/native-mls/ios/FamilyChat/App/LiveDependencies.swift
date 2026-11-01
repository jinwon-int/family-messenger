// `AppModel.Dependencies.live()` — 실제 구현 조립(파이널라이저 통합, #271).
//
//  - 엔진: ios-ffi xcframework `FfiEngineFactory`(방 상태 시드는 AppModel 의 `SeededEngineFactory`, 결정 D2)
//  - MLS 상태: L1 `FileStateStore`(`<base>/mls/<room>.state`, flock 단일 작성자, 원자 영속,
//    봉인 = CryptoKit ChaChaPoly + Keychain 32B 키 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
//  - 메시지·outbox·커서: L1 `FileSQLiteStore`(`<base>/messages.db`, 한 DB)
//  - 릴레이: L3 `URLSessionRelayTransport`(주소 = **선택한 서버** `hande.server`(App Group) → 빌드 기본값 Info.plist `FamilyChatRelayURL`
//    (빌드 설정 `FC_RELAY_URL`, 가족 TestFlight) → 없으면 서버 선택 화면(#584 PR 2, App Store 빌드))
//  - 푸시 등록: `PushRegistrar`(topic = Info.plist `FamilyChatPushTopic`, 빌드 설정 `FC_PUSH_TOPIC` = 기본 Bundle ID)
//
// `<base>` = Info.plist `FamilyChatAppGroup`(빌드 설정 `FC_APP_GROUP`)의 App Group 컨테이너 **아래 서버 스코프** `servers/<id>/`
// (`ServerScope`, #584 — 서버를 바꿔도 데이터가 섞이지 않는다). NSE(§12-D)가 같은 상태를 열려면 App Group 이 필요하다. 설정이 비었거나
// 컨테이너를 못 얻으면(무서명 시뮬레이터·CI) 앱 전용 Application Support 로 폴백한다 — 이때는 NSE 와 공유되지 않는다.
// 저장소를 열지 못하면 `startupFailure` 로 fatal 화면에 사유를 보인다.
// 봉인 키·릴레이 자격증명(Keychain 접근 그룹)·기기 ID(App Group defaults)도 같은 App Group 으로 공유한다(SharedStorage.swift, 결정 D8).
// 옛 설치(스코프 없는 경로)는 첫 실행에 `LegacyScopeMigration` 이 빌드 기본 서버의 스코프로 한 번 옮긴다.
// 실제 호스트명·Bundle ID·Team ID 는 리포에 두지 않는다(CONTRIBUTING) — 빌드 설정으로 주입.
import Foundation
import FamilyMLSCore
#if canImport(UserNotifications)
import UserNotifications
#endif

extension AppModel.Dependencies {
    struct LiveConfiguration {
        /// #584 선택한 서버. nil = 서버 선택 화면(`.needsServer`). 기본 = 테스트 서버(TwoDeviceScenario 등이 화면 없이 조립) —
        /// `fromBundle` 이 App Group `hande.server` → 빌드 기본값 순으로 **항상** 다시 정한다.
        var server: ServerSelection? = .testing
        /// 빌드 설정 `FC_RELAY_URL`(Info.plist `FamilyChatRelayURL`) — 서버 선택 화면 미리 채움. App Store 빌드는 nil.
        var defaultRelayURL: URL?
        var serverStore: ServerStoring = InMemoryServerStore()
        /// 서버 탐색. nil = URLSession 실구현(`ServerDiscoverer`). 테스트는 표를 준다.
        var discoverServer: ((String) async -> Result<ServerInfo, ServerDiscoveryFailure>)?
        /// 마케팅 버전(`CFBundleShortVersionString`) — `.well-known` 의 `min_app.ios` 와 비교.
        var appVersion = "0.0.0"
        /// 서버를 고르거나 바꾼 뒤 의존성을 다시 조립하는 길. nil = AppModel 이 그 자리에서 `server` 만 바꾼다(테스트).
        var reopen: ((ServerSelection?) -> AppModel.Dependencies)?
        var appGroup: String?
        /// 테스트가 임시 디렉터리를 줄 때만 쓴다. nil = App Group 또는 Application Support.
        var baseDirectory: URL?
        /// nil = 플랫폼 기본 봉인(ChaChaPoly + Keychain, App Group 이 열리면 공유 그룹). 테스트는 정적 키 봉인을 준다.
        var sealer: FileStateSealing?
        /// nil = Keychain(공유 그룹, 서버 스코프 account). 테스트는 메모리 저장소를 준다.
        var credentials: CredentialStoring?
        var identityProvider: () -> DeviceID = { DeviceIdentity.stableDeviceId(actor: "owner") }
        /// APNs topic(= Bundle ID). nil = 푸시 등록 안 함(테스트 기본).
        var pushTopic: String?
        /// 사용자 이름(actor) 저장소. 기본 = 이미 "owner" 로 고름(테스트).
        var actorStore: ActorStoring = InMemoryActorStore("owner")
        /// 참여 요청 기본 대화방(Info.plist `FamilyChatDefaultRoom`, 비면 "family" — 사람 가족 방, #383).
        var defaultRoom: RoomID = "family"
        /// 에이전트 actor(#405 — Info.plist `FamilyChatAgentActors` ← 빌드 설정 `FC_AGENT_ACTORS`, NSE 와 같은 값).
        var agentRoster = AgentRoster(actors: ["bot"])

        /// 로그인 시트가 여는 릴레이 주소 = 선택한 서버.
        var relayURL: URL? { server?.baseURL }

        static func fromBundle(_ bundle: Bundle = .main) -> Self {
            let group = bundle.familyChatValue("FamilyChatAppGroup")
            var config = Self()
            config.appGroup = group
            config.pushTopic = bundle.familyChatValue("FamilyChatPushTopic")
            config.defaultRelayURL = bundle.familyChatValue("FamilyChatRelayURL").flatMap(URL.init(string:))
            config.appVersion = bundle.familyChatValue("CFBundleShortVersionString") ?? "0.0.0"
            config.reopen = { _ in AppModel.Dependencies.live() }
            if let room = bundle.familyChatValue("FamilyChatDefaultRoom") { config.defaultRoom = room }
            if let agents = bundle.familyChatValue("FamilyChatAgentActors") { config.agentRoster = AgentRoster(setting: agents) }

            // #584: 서버 = App Group `hande.server`(선택·비움) → 빌드 기본값 → 없음(서버 선택 화면).
            let shared = SharedStorage.defaults(appGroup: group)
            let store = DefaultsServerStore(defaults: shared)
            config.serverStore = store
            let state = store.load()
            config.server = ServerStore.resolve(state, defaultURL: config.defaultRelayURL)
            guard let server = config.server else { return config }
            let scope = ServerScope(baseURL: server.baseURL)
            if state == .unset, let root = try? storageRoot(config) {
                // 업데이트 뒤 첫 실행(저장된 선택 없음·기본값 있음): 옛 설치의 스코프 없는 데이터를 기본 서버 스코프로 옮기고 선택을 적는다
                // (이후 실행·NSE 는 `hande.server` 를 읽는다. 빌드 기본값이 나중에 바뀌어도 적어 둔 선택이 이긴다 — 「서버 바꾸기」로 옮긴다).
                LegacyScopeMigration.run(root: root, scope: scope, shared: shared, local: .standard,
                                         legacyCredentials: SharedStorage.legacyCredentialStore(appGroup: group),
                                         scopedCredentials: SharedStorage.credentialStore(appGroup: group, scope: scope))
                store.save(server)
            }
            let defaults = SharedStorage.scopedDefaults(appGroup: group, scope: scope)
            let actors = DefaultsActorStore(defaults: defaults)
            config.actorStore = actors
            // 기기 ID 는 bootstrap 이 actor 를 확인한 뒤에만 부른다(AppModel). 기존 ID 가 있으면 그대로.
            config.identityProvider = { DeviceIdentity.existingOrNew(actor: actors.actor ?? "owner", defaults: defaults) }
            return config
        }
    }

    static func live() -> Self { live(.fromBundle()) }

    static func live(_ config: LiveConfiguration) -> Self {
        let discover = config.discoverServer
            ?? ServerDiscoverer(fetch: ServerDiscoverer.urlSessionFetch(), appVersion: config.appVersion).discover
        func serverFields(_ deps: inout Self) {
            deps.server = config.server
            deps.serverStore = config.serverStore
            deps.defaultRelayURL = config.defaultRelayURL
            deps.discoverServer = discover
            deps.reopen = config.reopen
        }
        guard let server = config.server else {
            // 서버를 고르기 전: 스코프가 없으므로 아무 저장소도 열지 않는다 — bootstrap 은 `.needsServer` 로 간다(#584).
            var deps = Self(
                engineFactory: FfiEngineFactory(),
                stateStore: InMemoryStateStore(),
                messageStore: InMemoryMessageStore(),
                outbox: InMemoryOutboxStore(),
                cursors: InMemoryCursorStore(),
                identityProvider: config.identityProvider,
                expectedDecryptFormat: { FfiEngineFactory.reportedDecryptFormat() },
                makeTransport: { _ in nil },
                relayURL: nil)
            serverFields(&deps)
            return deps
        }
        let scope = ServerScope(baseURL: server.baseURL)
        let makeTransport: (RelayCredential) -> RelayTransport? = { credential in
            URLSessionRelayTransport(baseURL: server.baseURL, credential: credential)
        }
        do {
            let base = try storageDirectory(config)
            let sealer = try config.sealer ?? SharedStorage.sealer(appGroup: config.appGroup)
            let stateStore = try FileStateStore(directory: base.appendingPathComponent("mls", isDirectory: true), sealer: sealer)
            let database = try FileSQLiteStore(directory: base)
            // "이 기기 지우기": MLS 상태(identity 포함, 방마다 flock) → DB 행 → 기기 ID(suite·standard). 봉인 키는 유지(AppModel.wipeDevice).
            var wipe = AppModel.DeviceWipe()
            wipe.storage = { try stateStore.removeAllState(timeout: 5); try database.wipe() }
            wipe.identity = { SharedStorage.wipeIdentity(appGroup: config.appGroup, scope: scope) }
            var deps = Self(
                engineFactory: FfiEngineFactory(),
                stateStore: stateStore,
                messageStore: database,
                outbox: database,
                cursors: database,
                identityProvider: config.identityProvider,
                expectedDecryptFormat: { FfiEngineFactory.reportedDecryptFormat() },
                makeTransport: makeTransport,
                relayURL: server.baseURL,
                push: config.pushTopic.map { PushRegistrar.Dependencies.live(topic: $0, records: scope.defaults(.standard)) }
                    ?? PushRegistrar.Dependencies(topic: nil),
                credentials: config.credentials ?? SharedStorage.credentialStore(appGroup: config.appGroup, scope: scope),
                actorStore: config.actorStore,
                defaultRoom: config.defaultRoom,
                wipe: wipe,
                agentRoster: config.agentRoster,
                lockScreenPreview: Self.liveLockScreenPreview)
            // #574: 형제 기기 초대 대기열(기기별, 30분 TTL)은 App Group defaults 에 — 기기 ID 와 같은 자리, 비밀 아님.
            // 키가 기기 ID 를 품고 기기 ID 는 서버 스코프마다 새로 나므로 따로 스코프하지 않는다(#584).
            deps.siblingQueue = UserDefaultsSiblingQueueStore(defaults: SharedStorage.defaults(appGroup: config.appGroup))
            // #584: 읽음 위치·방 순서(앱 전용 defaults)도 서버 스코프.
            deps.localDefaults = scope.defaults(.standard)
            // #643: 공유 확장 맡김·공유 대상 방 목록 — App Group 이 있을 때만(확장이 같은 컨테이너·같은 스코프 defaults 를 본다).
            if let container = SharedStorage.appGroupContainer(config.appGroup) {
                deps.shareStore = ShareHandoffStore(container: container)
                deps.shareTargets = SharedStorage.scopedDefaults(appGroup: config.appGroup, scope: scope)
                deps.deliverSharesWhenReady = true
                deps.shareDelivered = Self.removeShareNotification
            }
            serverFields(&deps)
            return deps
        } catch {
            // 화면이 사유를 보여 줄 수 있게 메모리 스토어로 모델만 세운다(아무것도 저장하지 않는다).
            var deps = Self(
                engineFactory: FfiEngineFactory(),
                stateStore: InMemoryStateStore(),
                messageStore: InMemoryMessageStore(),
                outbox: InMemoryOutboxStore(),
                cursors: InMemoryCursorStore(),
                identityProvider: config.identityProvider,
                expectedDecryptFormat: { FfiEngineFactory.reportedDecryptFormat() },
                makeTransport: makeTransport,
                relayURL: server.baseURL,
                startupFailure: Strings.storageUnavailable("\(error)"))
            serverFields(&deps)
            return deps
        }
    }

    /// #520: 잠금화면 미리보기 설정 읽기. UserNotifications 가 없는 Linux 스모크에서는 모름.
    /// #643 보낸 맡김의 「누르면 보냅니다」 알림을 알림 센터에서 지운다(확장이 `hande.share.<id>` 로 띄웠다).
    static func removeShareNotification(_ id: String) {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["hande.share.\(id)"])
        #endif
    }

    static func liveLockScreenPreview() async -> LockScreenPreview {
        #if canImport(UserNotifications)
        return await LockScreenPreview.readLive()
        #else
        return .unknown
        #endif
    }

    /// 스코프 없는 저장 뿌리: 테스트 디렉터리 → App Group 컨테이너 → 앱 전용 Application Support/FamilyChat.
    static func storageRoot(_ config: LiveConfiguration) throws -> URL {
        if let base = config.baseDirectory { return base }
        if let group = config.appGroup,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return container
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("FamilyChat", isDirectory: true)
    }

    /// 실제 저장 디렉터리 = 뿌리 아래 서버 스코프 `servers/<id>/`(#584). 서버가 없으면 뿌리(그때는 저장소를 열지 않는다).
    static func storageDirectory(_ config: LiveConfiguration) throws -> URL {
        let root = try storageRoot(config)
        guard let server = config.server else { return root }
        return ServerScope(baseURL: server.baseURL).directory(in: root)
    }
}

extension Bundle {
    /// Info.plist 의 빌드 설정 주입 값(빈 문자열 = 미설정).
    func familyChatValue(_ key: String) -> String? {
        guard let raw = object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
