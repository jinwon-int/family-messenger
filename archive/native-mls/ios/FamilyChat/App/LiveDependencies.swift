// `AppModel.Dependencies.live()` — 실제 구현 조립(파이널라이저 통합, #271).
//
//  - 엔진: ios-ffi xcframework `FfiEngineFactory`(방 상태 시드는 AppModel 의 `SeededEngineFactory`, 결정 D2)
//  - MLS 상태: L1 `FileStateStore`(`<base>/mls/<room>.state`, flock 단일 작성자, 원자 영속,
//    봉인 = CryptoKit ChaChaPoly + Keychain 32B 키 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
//  - 메시지·outbox·커서: L1 `FileSQLiteStore`(`<base>/messages.db`, 한 DB)
//  - 릴레이: L3 `URLSessionRelayTransport`(주소 = Info.plist `FamilyChatRelayURL`, 빌드 설정 `FC_RELAY_URL`)
//  - 푸시 등록: `PushRegistrar`(topic = Info.plist `FamilyChatPushTopic`, 빌드 설정 `FC_PUSH_TOPIC` = 기본 Bundle ID)
//
// `<base>` = Info.plist `FamilyChatAppGroup`(빌드 설정 `FC_APP_GROUP`)의 App Group 컨테이너. NSE(§12-D)가 같은 상태를
// 열려면 App Group 이 필요하다. 설정이 비었거나 컨테이너를 못 얻으면(무서명 시뮬레이터·CI) 앱 전용 Application Support 로
// 폴백한다 — 이때는 NSE 와 공유되지 않는다. 저장소를 열지 못하면 `startupFailure` 로 fatal 화면에 사유를 보인다.
// 봉인 키·릴레이 자격증명(Keychain 접근 그룹)·기기 ID(App Group defaults)도 같은 App Group 으로 공유한다(SharedStorage.swift, 결정 D8).
// 실제 호스트명·Bundle ID·Team ID 는 리포에 두지 않는다(CONTRIBUTING) — 빌드 설정으로 주입.
import Foundation
import FamilyMLSCore

extension AppModel.Dependencies {
    struct LiveConfiguration {
        var relayURL: URL?
        var appGroup: String?
        /// 테스트가 임시 디렉터리를 줄 때만 쓴다. nil = App Group 또는 Application Support.
        var baseDirectory: URL?
        /// nil = 플랫폼 기본 봉인(ChaChaPoly + Keychain, App Group 이 열리면 공유 그룹). 테스트는 정적 키 봉인을 준다.
        var sealer: FileStateSealing?
        /// nil = Keychain(공유 그룹). 테스트는 메모리 저장소를 준다.
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

        static func fromBundle(_ bundle: Bundle = .main) -> Self {
            let group = bundle.familyChatValue("FamilyChatAppGroup")
            var config = Self(relayURL: bundle.familyChatValue("FamilyChatRelayURL").flatMap(URL.init(string:)), appGroup: group)
            config.pushTopic = bundle.familyChatValue("FamilyChatPushTopic")
            let defaults = SharedStorage.defaults(appGroup: group)
            let actors = DefaultsActorStore(defaults: defaults)
            config.actorStore = actors
            // 기기 ID 는 bootstrap 이 actor 를 확인한 뒤에만 부른다(AppModel). 기존 ID 가 있으면 그대로.
            config.identityProvider = { DeviceIdentity.existingOrNew(actor: actors.actor ?? "owner", defaults: defaults) }
            if let room = bundle.familyChatValue("FamilyChatDefaultRoom") { config.defaultRoom = room }
            if let agents = bundle.familyChatValue("FamilyChatAgentActors") { config.agentRoster = AgentRoster(setting: agents) }
            return config
        }
    }

    static func live() -> Self { live(.fromBundle()) }

    static func live(_ config: LiveConfiguration) -> Self {
        let makeTransport: (RelayCredential) -> RelayTransport? = { credential in
            config.relayURL.map { URLSessionRelayTransport(baseURL: $0, credential: credential) }
        }
        do {
            let base = try storageDirectory(config)
            let sealer = try config.sealer ?? SharedStorage.sealer(appGroup: config.appGroup)
            let stateStore = try FileStateStore(directory: base.appendingPathComponent("mls", isDirectory: true), sealer: sealer)
            let database = try FileSQLiteStore(directory: base)
            // "이 기기 지우기": MLS 상태(identity 포함, 방마다 flock) → DB 행 → 기기 ID(suite·standard). 봉인 키는 유지(AppModel.wipeDevice).
            var wipe = AppModel.DeviceWipe()
            wipe.storage = { try stateStore.removeAllState(timeout: 5); try database.wipe() }
            wipe.identity = { SharedStorage.wipeIdentity(appGroup: config.appGroup) }
            var deps = Self(
                engineFactory: FfiEngineFactory(),
                stateStore: stateStore,
                messageStore: database,
                outbox: database,
                cursors: database,
                identityProvider: config.identityProvider,
                expectedDecryptFormat: { FfiEngineFactory.reportedDecryptFormat() },
                makeTransport: makeTransport,
                relayURL: config.relayURL,
                push: config.pushTopic.map { PushRegistrar.Dependencies.live(topic: $0) } ?? PushRegistrar.Dependencies(topic: nil),
                credentials: config.credentials ?? SharedStorage.credentialStore(appGroup: config.appGroup),
                actorStore: config.actorStore,
                defaultRoom: config.defaultRoom,
                wipe: wipe,
                agentRoster: config.agentRoster,
                lockScreenPreview: Self.liveLockScreenPreview)
            // #574: 형제 기기 초대 대기열(기기별, 30분 TTL)은 App Group defaults 에 — 기기 ID 와 같은 자리, 비밀 아님.
            deps.siblingQueue = UserDefaultsSiblingQueueStore(defaults: SharedStorage.defaults(appGroup: config.appGroup))
            return deps
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
                relayURL: config.relayURL,
                startupFailure: Strings.storageUnavailable("\(error)"))
        }
    }

    /// #520: 잠금화면 미리보기 설정 읽기. UserNotifications 가 없는 Linux 스모크에서는 모름.
    static func liveLockScreenPreview() async -> LockScreenPreview {
        #if canImport(UserNotifications)
        return await LockScreenPreview.readLive()
        #else
        return .unknown
        #endif
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

extension Bundle {
    /// Info.plist 의 빌드 설정 주입 값(빈 문자열 = 미설정).
    func familyChatValue(_ key: String) -> String? {
        guard let raw = object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
