// 잠금화면 본문 노출 없음 (#520, #243 2-c 기준 「나」 — 오너 결정 2026-10-27). 설계 B: 잠금 상태에서만 숨긴다.
//
//   - NSE 는 지금처럼 복호화한 제목·본문을 넣고, **모든** 알림(복호화·대체)에 카테고리 `NotificationCategory.message` 를 단다.
//   - 앱은 시작할 때 그 카테고리를 `hiddenPreviewsBodyPlaceholder`(일반 문구)와 함께 등록한다. 옵션에 `hiddenPreviewsShowTitle`
//     을 넣지 않으므로 미리보기를 숨길 때는 제목(보낸 사람)도 숨는다.
//   - iOS 는 미리보기 설정이 「잠금 해제 시」(`.whenAuthenticated`)·「안 함」(`.never`)일 때만 이 일반 문구를 쓴다.
//     「항상」(`.always`)이면 잠금화면에도 본문이 나오므로 앱이 그 값을 읽어 경고한다(`LockScreenPreview.needsWarning`).
//   - 잠금 해제 상태의 배너 본문은 그대로다 — #271 §12-D 10건 표본 기준 「본문 10/10」과 부딪히지 않는다(설계 A 와의 차이).
//
// 한계: 기기 설정에 의존한다. Face ID 기기는 잠금화면을 바라보기만 해도 인증되어 「잠금 해제 시」에서도 본문이 펼쳐진다
// (iOS 설계). 측정은 인증되지 않은 잠금 상태에서 하고, 설정 화면의 「잠금화면 미리보기」 값을 함께 기록한다.
//
// 이 파일은 앱·NSE·Linux 스모크가 함께 컴파일한다. UserNotifications 가 없는 Linux 에서는 순수 판정만 남는다.
import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// 알림 카테고리 — NSE 가 달고 앱이 등록한다. 서버 페이로드(apns.go)는 카테고리를 싣지 않는다.
enum NotificationCategory {
    static let message = "fc.message"
}

/// 이 기기에서 잠금화면에 메시지 본문이 보일 수 있는가 — 설정 화면 표시와 경고 판정용.
enum LockScreenPreview: Equatable {
    /// 아직 읽지 않았다(시작 직후·이 플랫폼에서 읽을 수 없음).
    case unknown
    /// 알림 권한이 없거나 잠금화면 알림이 꺼져 있다 — 잠금화면에 아무것도 없다.
    case off
    /// 「잠금 해제 시」 — 잠금 상태에서는 일반 문구(권장값).
    case whenUnlocked
    /// 「안 함」 — 언제나 일반 문구.
    case never
    /// 「항상」 — 잠금화면에도 본문이 보인다(경고).
    case always

    /// iOS 미리보기 설정 값(UNShowPreviewsSetting 의 플랫폼 무관 대역).
    enum Previews: Equatable { case always, whenUnlocked, never, unknown }

    /// 순수 판정(테스트 대상). 권한 없음·잠금화면 꺼짐이 먼저다 — 그때는 미리보기 값과 무관하게 노출이 없다.
    static func classify(authorized: Bool, lockScreenEnabled: Bool, previews: Previews) -> LockScreenPreview {
        guard authorized, lockScreenEnabled else { return .off }
        switch previews {
        case .always: return .always
        case .whenUnlocked: return .whenUnlocked
        case .never: return .never
        case .unknown: return .unknown
        }
    }

    /// 「항상」일 때만 경고한다.
    var needsWarning: Bool { self == .always }
}

#if canImport(UserNotifications)
extension NotificationCategory {
    /// 앱이 등록하는 카테고리. 동작 버튼 없음, 숨김 시 제목도 숨김(옵션 비움).
    static func messageCategory() -> UNNotificationCategory {
        UNNotificationCategory(identifier: message, actions: [], intentIdentifiers: [],
                               hiddenPreviewsBodyPlaceholder: Strings.pushHiddenPreviewPlaceholder, options: [])
    }
}

/// NSE 가 알림 내용을 바꾸는 유일한 경로(앱 테스트가 같은 코드를 검사한다).
enum NotificationContentWriter {
    static func apply(_ result: ProcessedNotification, to content: UNMutableNotificationContent) {
        content.title = result.title
        content.body = result.body
        content.categoryIdentifier = NotificationCategory.message
    }
}

extension LockScreenPreview {
    /// 운영: 이 앱의 알림 설정을 읽는다(설정 앱에서 앱별로 바꾼 값이 반영된 실효값).
    static func readLive() async -> LockScreenPreview {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorized: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: authorized = true
        default: authorized = false
        }
        let previews: Previews
        switch settings.showPreviewsSetting {
        case .always: previews = .always
        case .whenAuthenticated: previews = .whenUnlocked
        case .never: previews = .never
        @unknown default: previews = .unknown
        }
        return classify(authorized: authorized, lockScreenEnabled: settings.lockScreenSetting == .enabled, previews: previews)
    }
}
#endif
