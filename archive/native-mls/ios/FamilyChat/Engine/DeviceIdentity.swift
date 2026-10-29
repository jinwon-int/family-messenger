// 기기 ID `<actor>-iphone-<6hex>` (relay-app 규칙: 첫 `-` 앞 = actor). 한 설치에 하나. 앱 삭제·복원 = 새 기기(설계 §5).
// 키체인 영속은 L1 범위가 아니라 앱(파이널라이저) 몫이지만, 뼈대에서는 UserDefaults 에 ID 만 둔다(비밀 아님).
import Foundation

enum DeviceIdentity {
    static let defaultsKey = "familychat.deviceId"

    static func stableDeviceId(actor: String, defaults: UserDefaults = .standard) -> String {
        stableDeviceId(actor: actor, defaults: ScopedDefaults(defaults))
    }

    /// #584: 서버별 스코프 키(`ScopedDefaults`). 스코프 없는 겉면(위)은 옛 설치·테스트와 같은 키.
    static func stableDeviceId(actor: String, defaults: ScopedDefaults) -> String {
        if let existing = defaults.string(forKey: defaultsKey), existing.hasPrefix(actor + "-") { return existing }
        let fresh = generate(actor: actor)
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }

    /// 저장된 기기 ID 가 있으면 actor 와 무관하게 그대로(설치당 하나 — actor 를 바꾼다고 새 기기를 만들지 않는다),
    /// 없으면 `actor` 로 새로 만든다. 앱(live)은 이것을 쓴다.
    static func existingOrNew(actor: String, defaults: UserDefaults = .standard) -> String {
        existingOrNew(actor: actor, defaults: ScopedDefaults(defaults))
    }

    static func existingOrNew(actor: String, defaults: ScopedDefaults) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty { return existing }
        let fresh = generate(actor: actor)
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }

    /// "이 기기 지우기"(§9-5): 저장된 기기 ID 를 지운다 — 다음 `existingOrNew` 가 새 ID 를 만든다. 옛 ID 는 릴레이에서 재사용 금지
    /// (tombstone, DEVICES-V4)라 되살리면 안 되므로 App Group suite 와 **앱 전용 standard 양쪽**을 지운다(SharedStorage 가 standard 의
    /// 옛 값을 suite 로 1회 옮기는 경로가 있어, standard 를 남기면 지운 ID 가 되살아난다).
    static func reset(defaults: UserDefaults) {
        reset(defaults: ScopedDefaults(defaults))
    }

    /// 스코프 키와 함께 옛 스코프 없는 키(suite·standard)도 지운다 — 이관 경로가 옛 값을 되살리지 못하게.
    static func reset(defaults: ScopedDefaults) {
        defaults.removeObject(forKey: defaultsKey)
        defaults.base.removeObject(forKey: defaultsKey)
        if defaults.base !== UserDefaults.standard { UserDefaults.standard.removeObject(forKey: defaultsKey) }
    }

    static func generate(actor: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 3)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(actor)-iphone-\(hex)"
    }

    // 등록 정보(운영자 CLI `-enroll-first`/`-add-device` 입력)는 Core `EnrollmentRequest` 하나로 만든다(AppModel.registration).

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

// MARK: - 사용자 이름(actor) — 가족 투입(#271 §5)

/// actor 규칙: 소문자로 시작하는 영문 소문자·숫자 2~16자. `-` 는 기기 ID 의 구분자라 금지(relay-app `actorOf`, DEVICES-V4).
enum ActorName {
    static func isValid(_ name: String) -> Bool {
        guard (2...16).contains(name.count), let first = name.unicodeScalars.first,
              ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// 기기 ID 의 첫 `-` 앞(= actor). 형식이 맞지 않으면 nil.
    static func of(deviceId: String) -> String? {
        guard let head = deviceId.split(separator: "-", maxSplits: 1).first.map(String.init),
              deviceId.contains("-"), isValid(head) else { return nil }
        return head
    }
}

/// 이 기기 사용자 이름 저장소. `actor == nil` = 첫 실행이라 아직 고르지 않음.
protocol ActorStoring: AnyObject {
    var actor: String? { get }
    func save(_ actor: String)
}

final class InMemoryActorStore: ActorStoring {
    private(set) var actor: String?
    init(_ actor: String?) { self.actor = actor }
    func save(_ actor: String) { self.actor = actor }
}

/// 앱(live): 기기 ID 와 같은 defaults(App Group). 저장된 actor 가 없어도 기존 기기 ID 가 있으면 거기서 actor 를 읽는다 —
/// 이 PR 이전 설치(오너 `owner-iphone-…`)는 이름 선택 화면을 보지 않고 그대로 이어 간다.
final class DefaultsActorStore: ActorStoring {
    static let key = "familychat.actor"
    private let defaults: ScopedDefaults

    init(defaults: ScopedDefaults) { self.defaults = defaults }
    convenience init(defaults: UserDefaults) { self.init(defaults: ScopedDefaults(defaults)) }

    var actor: String? {
        if let saved = defaults.string(forKey: Self.key), ActorName.isValid(saved) { return saved }
        return defaults.string(forKey: DeviceIdentity.defaultsKey).flatMap(ActorName.of(deviceId:))
    }

    func save(_ actor: String) { defaults.set(actor, forKey: Self.key) }
}
