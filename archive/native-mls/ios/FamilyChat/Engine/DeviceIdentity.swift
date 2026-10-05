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

    /// 등록 정보(운영자 CLI `-enroll-first`/`-add-device` 입력과 같은 키). `subject` 는 CF Access `sub` — 로그인 후 채워진다.
    struct Registration: Codable, Equatable {
        var deviceId: String
        var actor: String
        var subject: String
        var signingKey: String   // lowercase hex
        var fingerprint: String  // sha256(signing key) hex
        enum CodingKeys: String, CodingKey { case actor, subject, fingerprint; case deviceId = "device_id", signingKey = "signing_key" }

        func json() -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
