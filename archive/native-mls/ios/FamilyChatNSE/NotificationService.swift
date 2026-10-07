// 알림 확장(NSE) 진입점 — §12-D, #271 §8. 처리 로직은 앱과 공유하는 `NotificationProcessor`(FamilyChat/Push/).
//
// 이 프로세스는 앱과 같은 App Group 컨테이너의 MLS 상태·messages.db 를 같은 flock 규칙으로 연다(결정 D4).
// App Group 이 열리지 않는 빌드(무서명·설정 없음)에서는 아무것도 열지 않고 대체 알림만 낸다 — NSE 가 자기 샌드박스에
// 새 상태를 만들면 앱과 갈라진 두 번째 기기가 되기 때문이다(기기 ID 도 읽기만 하고 만들지 않는다).
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

    static func apply(_ result: ProcessedNotification, to content: UNMutableNotificationContent) {
        content.title = result.title
        content.body = result.body
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
        guard let container = SharedStorage.appGroupContainer(group),
              let sealer = try? SharedStorage.sealer(appGroup: group),
              let stateStore = try? FileStateStore(directory: container.appendingPathComponent("mls", isDirectory: true), sealer: sealer),
              let database = try? FileSQLiteStore(directory: container) else {
            return nil
        }
        let relayURL = value("FamilyChatRelayURL").flatMap(URL.init(string:))
        let credentials = SharedStorage.credentialStore(appGroup: group)
        return NotificationProcessor.Environment(
            identity: { SharedStorage.existingDeviceId(appGroup: group) },
            credential: { credentials.load() },
            makeTransport: { credential in
                // NSE 예산 안: 요청 하나 10 s(앱은 30 s).
                relayURL.map { URLSessionRelayTransport(baseURL: $0, credential: credential, requestTimeout: 10) }
            },
            engineFactory: FfiEngineFactory(),
            stateStore: stateStore,
            messages: database,
            outbox: database,
            cursors: database,
            agentActors: NotificationProcessor.agentActors(from: value("FamilyChatAgentActors")))
    }
}
