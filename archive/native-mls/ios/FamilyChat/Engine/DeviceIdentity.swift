// 기기 ID `<actor>-iphone-<6hex>` (relay-app 규칙: 첫 `-` 앞 = actor). 한 설치에 하나. 앱 삭제·복원 = 새 기기(설계 §5).
// 키체인 영속은 L1 범위가 아니라 앱(파이널라이저) 몫이지만, 뼈대에서는 UserDefaults 에 ID 만 둔다(비밀 아님).
import Foundation

enum DeviceIdentity {
    static let defaultsKey = "familychat.deviceId"

    static func stableDeviceId(actor: String, defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), existing.hasPrefix(actor + "-") { return existing }
        let fresh = generate(actor: actor)
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
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
