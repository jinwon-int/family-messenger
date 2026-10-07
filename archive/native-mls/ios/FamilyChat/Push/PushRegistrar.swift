// 푸시 등록(§12-D, 릴레이 확장 ② — CONTRACTS §2.3). 결정 D6(NOTES-FINALIZER.md):
//
//  - 등록된 기기(ready·halted)가 되면 이 실행에서 한 번 알림 권한을 묻고, 허용이면 `registerForRemoteNotifications`.
//    미등록 기기는 릴레이가 403(JWT subject ↔ device)으로 거절하므로 그 전에는 묻지도 보내지도 않는다.
//  - 토큰을 받으면 (device, token, topic) 이 마지막 성공과 다르거나, 로그인 뒤 첫 회이거나, 24시간이 지났을 때만 POST.
//    서버는 같은 기기를 upsert 하므로(토큰 교체) 다시 보내도 안전하다 — 정책은 불필요한 왕복을 줄이는 것뿐.
//  - 실패는 지수 백오프(1분 → 최대 1시간). 401 은 호출자(AppModel)에게 넘겨 동기화와 같이 재로그인으로 보낸다.
//  - 로그아웃 = DELETE(최선). 실패해도 로컬 기록은 지운다 — 이후 오는 푸시는 NSE 가 자격증명이 없어 대체 알림만 보인다.
//  - topic = Bundle ID(빌드 설정 `FC_PUSH_TOPIC` → Info.plist `FamilyChatPushTopic`). 비면 등록하지 않는다.
// 토큰은 비밀이 아니지만 화면·로그에 내지 않는다(기기 추적 식별자).
import Foundation
import FamilyMLSCore
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

/// 릴레이가 마지막으로 받아 준 등록.
struct PushRegistrationRecord: Codable, Equatable {
    var device: DeviceID
    var token: Data
    var topic: String
    var registeredAt: Date
}

protocol PushRecordStoring: AnyObject {
    func load() -> PushRegistrationRecord?
    func save(_ record: PushRegistrationRecord?)
}

final class InMemoryPushRecordStore: PushRecordStoring {
    private var record: PushRegistrationRecord?
    init(_ record: PushRegistrationRecord? = nil) { self.record = record }
    func load() -> PushRegistrationRecord? { record }
    func save(_ record: PushRegistrationRecord?) { self.record = record }
}

/// 앱 전용 UserDefaults(NSE 는 등록하지 않으므로 공유할 필요 없다).
final class UserDefaultsPushRecordStore: PushRecordStoring {
    static let key = "familychat.push.registration.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> PushRegistrationRecord? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(PushRegistrationRecord.self, from: $0) }
    }
    func save(_ record: PushRegistrationRecord?) {
        if let record, let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Self.key) }
        else { defaults.removeObject(forKey: Self.key) }
    }
}

@MainActor
final class PushRegistrar {
    enum Status: Equatable {
        /// 아직 등록된 기기가 아니거나 로그아웃.
        case off
        /// 이 빌드·기기에서 쓸 수 없다(topic 미설정·권한 거부·토큰 발급 실패).
        case unavailable(String)
        case waitingForToken
        case registered(Date)
        /// 릴레이 등록 실패 — 백오프 뒤 다시 시도한다.
        case failed(String)
    }

    struct Policy {
        var refreshInterval: TimeInterval = 24 * 3600
        var initialBackoff: TimeInterval = 60
        var maxBackoff: TimeInterval = 3600
    }

    struct Dependencies {
        var topic: String?
        var records: PushRecordStoring = InMemoryPushRecordStore()
        /// 권한 요청 → 허용이면 `registerForRemoteNotifications`. 콜백 = 거부 사유(nil = 토큰 요청함).
        var requestToken: @MainActor (@escaping @MainActor (String?) -> Void) -> Void = { _ in }
        var now: () -> Date = Date.init
        var policy = Policy()
    }

    private(set) var status: Status = .off
    private(set) var token: Data?
    private let deps: Dependencies
    private var tokenRequested = false
    private var forceNext = false
    private var failures = 0
    private var retryAfter: Date?

    init(_ dependencies: Dependencies) { self.deps = dependencies }

    var topic: String? { deps.topic }

    /// 등록된 기기가 됐다 — 이 실행에서 한 번만 토큰을 요청한다(토큰이 바뀌면 시스템이 다시 콜백한다).
    func activate() {
        guard deps.topic != nil else { status = .unavailable(Strings.pushNoTopic); return }
        guard !tokenRequested else { return }
        tokenRequested = true
        if token == nil { status = .waitingForToken }
        deps.requestToken { [weak self] denial in
            guard let self, let denial else { return }
            self.status = .unavailable(denial)
        }
    }

    func tokenReceived(_ token: Data) {
        guard token != self.token else { return }
        self.token = token
        failures = 0
        retryAfter = nil
    }

    func tokenFailed(_ reason: String) {
        status = .unavailable(reason)
    }

    /// 새 자격증명 — 다음 동기화에서 한 번은 다시 등록한다(다른 계정·만료 뒤 재로그인).
    func loggedIn() {
        forceNext = true
        failures = 0
        retryAfter = nil
    }

    /// 필요하면 등록한다. 반환 = 이번에 POST 했는가. 401 만 던진다(재로그인), 나머지 실패는 상태·백오프로 흡수.
    @discardableResult
    func syncIfNeeded(device: DeviceID, transport: RelayTransport) async throws -> Bool {
        guard let topic = deps.topic, let token else { return false }
        let now = deps.now()
        if let current = deps.records.load(), !forceNext,
           current.device == device, current.token == token, current.topic == topic,
           now.timeIntervalSince(current.registeredAt) < deps.policy.refreshInterval {
            status = .registered(current.registeredAt)
            return false
        }
        if let retryAfter, now < retryAfter { return false }
        do {
            try await transport.registerPush(PushRegistration(device: device, apnsToken: token, topic: topic))
        } catch RelayError.unauthorized {
            throw RelayError.unauthorized
        } catch {
            failures += 1
            let delay = min(deps.policy.initialBackoff * pow(2, Double(failures - 1)), deps.policy.maxBackoff)
            retryAfter = now.addingTimeInterval(delay)
            status = .failed(Self.describe(error))
            return false
        }
        deps.records.save(PushRegistrationRecord(device: device, token: token, topic: topic, registeredAt: now))
        forceNext = false
        failures = 0
        retryAfter = nil
        status = .registered(now)
        return true
    }

    /// 로그아웃: 로컬 기록을 지우고(항상) 릴레이에 DELETE(최선). 다음 로그인·ready 에서 다시 등록한다.
    func unregister(device: DeviceID, transport: RelayTransport?) async {
        deps.records.save(nil)
        status = .off
        forceNext = false
        failures = 0
        retryAfter = nil
        guard let transport, !device.isEmpty else { return }
        try? await transport.unregisterPush(device: device)
    }

    private static func describe(_ error: Error) -> String {
        if case RelayError.refused(let code, let status) = error { return "\(code) (\(status))" }
        if case RelayError.network = error { return Strings.pushNetwork }
        return "\(error)"
    }
}

extension PushRegistrar.Dependencies {
    /// 운영: 알림 권한(alert·sound·badge)을 묻고 허용이면 APNs 토큰을 요청한다. 토큰은 AppDelegate 콜백으로 온다.
    /// (UIKit 이 없는 Linux 스모크에서는 요청하지 않는다 — 등록 정책 자체는 플랫폼 무관.)
    static func live(topic: String) -> Self {
        var deps = Self(topic: topic)
        deps.records = UserDefaultsPushRecordStore()
        #if canImport(UIKit)
        deps.requestToken = { onDenied in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                Task { @MainActor in
                    if granted { UIApplication.shared.registerForRemoteNotifications() }
                    else { onDenied(Strings.pushDenied) }
                }
            }
        }
        #endif
        return deps
    }
}
