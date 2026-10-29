// 알림 확장(NSE) 진입점 — §12-D, #271 §8. 처리 로직은 앱과 공유하는 `NotificationProcessor`(FamilyChat/Push/).
//
// 이 프로세스는 앱과 같은 App Group 컨테이너의 MLS 상태·messages.db 를 같은 flock 규칙으로 연다(결정 D4).
// App Group 이 열리지 않는 빌드(무서명·설정 없음)에서는 아무것도 열지 않고 대체 알림만 낸다 — NSE 가 자기 샌드박스에
// 새 상태를 만들면 앱과 갈라진 두 번째 기기가 되기 때문이다(기기 ID 도 읽기만 하고 만들지 않는다).
// #584: 서버는 App Group `hande.server`(앱이 적은 선택) → 빌드 기본값 `FamilyChatRelayURL` 순으로 읽고(앱과 같은 `ServerStore.resolve`),
// 그 서버 스코프 `servers/<id>/` 가 아직 없으면(업데이트 뒤 앱 첫 실행 전) 만들지 않고 대체 알림만 낸다.
//
// 전달 경로는 셋이고 OnceFlag 로 한 번만 나간다: 처리 결과 · 기한(25 s) 대체 · serviceExtensionTimeWillExpire 대체.
// 시작하자마자 내용 자체를 대체 문구로 바꿔 두므로, 어느 경로든 빈 알림이나 loc-key 원문은 나가지 않는다.
import UserNotifications
import FamilyMLSCore

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private let once = OnceFlag()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        Self.apply(.fallback("initial"), to: content)
        self.content = content

        let userInfo = request.content.userInfo
        Task.detached { [weak self] in
            let result = await NotificationDeadline.race {
                guard let environment = NSEEnvironment.live() else { return .fallback("no_shared_storage") }
                return await NotificationProcessor(environment).process(userInfo)
            }
            self?.deliver(result)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        deliver(.fallback("expired"))
    }

    private func deliver(_ result: ProcessedNotification) {
        guard once.claim(), let content, let contentHandler else { return }
        Self.apply(result, to: content)
        contentHandler(content)
    }

    /// 제목·본문 + 카테고리(#520: 잠금 상태에서는 앱이 등록한 일반 문구로 숨김) — `NotificationPrivacy.swift`.
    static func apply(_ result: ProcessedNotification, to content: UNMutableNotificationContent) {
        NotificationContentWriter.apply(result, to: content)
    }
}

/// NSE 의 운영 조립 — 앱의 `Dependencies.live()` 와 같은 저장소·봉인·전송, 단 App Group 이 필수이고 아무것도 새로 만들지 않는다.
enum NSEEnvironment {
    static func live(bundle: Bundle = .main) -> NotificationProcessor.Environment? {
        func value(_ key: String) -> String? {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let group = value("FamilyChatAppGroup")
        guard let container = SharedStorage.appGroupContainer(group) else { return nil }
        // #584: App Group 의 선택 → 빌드 기본값. 둘 다 없으면(App Store 빌드, 서버 선택 전) 열 것이 없다.
        let defaultURL = value("FamilyChatRelayURL").flatMap(URL.init(string:))
        guard let server = ServerStore.resolve(DefaultsServerStore(defaults: SharedStorage.defaults(appGroup: group)).load(),
                                               defaultURL: defaultURL) else { return nil }
        let scope = ServerScope(baseURL: server.baseURL)
        let directory = scope.directory(in: container)
        // 앱이 아직 이 스코프를 만들지 않았다(옛 설치의 이관 전) — NSE 는 만들지 않는다.
        guard FileManager.default.fileExists(atPath: directory.path),
              let sealer = try? SharedStorage.sealer(appGroup: group),
              let stateStore = try? FileStateStore(directory: directory.appendingPathComponent("mls", isDirectory: true), sealer: sealer),
              let database = try? FileSQLiteStore(directory: directory) else {
            return nil
        }
        let relayURL = server.baseURL
        let credentials = SharedStorage.credentialStore(appGroup: group, scope: scope)
        return NotificationProcessor.Environment(
            identity: { SharedStorage.existingDeviceId(appGroup: group, scope: scope) },
            credential: { credentials.load() },
            makeTransport: { credential in
                // NSE 예산 안: 요청 하나 10 s(앱은 30 s).
                URLSessionRelayTransport(baseURL: relayURL, credential: credential, requestTimeout: 10)
            },
            engineFactory: FfiEngineFactory(),
            stateStore: stateStore,
            messages: database,
            outbox: database,
            cursors: database,
            agentActors: NotificationProcessor.agentActors(from: value("FamilyChatAgentActors")))
    }
}
