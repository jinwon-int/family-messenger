// UIKit 콜백 → AppModel (§12-D). SwiftUI 앱은 원격 알림 토큰·알림 표시 콜백을 `UIApplicationDelegate`/
// `UNUserNotificationCenterDelegate` 로만 받는다. 모델은 이 객체가 소유하고 `FamilyChatApp` 이 화면에 건넨다.
//
// 결정 D7: 앱이 전면(active)일 때 온 알림은 시스템 배너를 억제하고(표시 옵션 []) 곧바로 동기화해 인앱으로 보인다.
// 백그라운드·비활성이면 NSE 가 바꾼 알림을 그대로 보인다. 알림을 누르면 동기화만 한다(방 이동은 §12-E 화면).
import UIKit
import UserNotifications
import FamilyMLSCore

/// 전면 알림 표시 정책(D7) — 순수 함수(테스트 대상).
enum ForegroundPresentation {
    static func options(appActive: Bool) -> UNNotificationPresentationOptions {
        appActive ? [] : [.banner, .list, .sound]
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel(dependencies: .live())
    private lazy var notificationDelegate = NotificationCenterDelegate(model: model)

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await model.pushTokenReceived(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        model.pushTokenFailed(error.localizedDescription)
    }
}

/// `UNUserNotificationCenterDelegate` 는 액터 격리가 없는 Objective-C 프로토콜이라 따로 둔다(시스템은 메인 스레드에서 부른다).
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let model = self.model
        Task { @MainActor in
            let active = UIApplication.shared.applicationState == .active
            completionHandler(ForegroundPresentation.options(appActive: active))
            if active { await model.receivedWhileActive() }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let model = self.model
        Task { @MainActor in
            await model.receivedWhileActive()
            completionHandler()
        }
    }
}
