// App ↔ NSE 공유 저장 (§12-D, 파이널라이저 결정 D8 — NOTES-FINALIZER.md).
//
// NSE 는 앱과 다른 프로세스·다른 앱 ID 라 앱 전용 저장소(UserDefaults.standard, 기본 Keychain 그룹, Application Support)를 못 본다.
// App Group 이 설정되고 컨테이너가 열리면(서명 빌드) 여기 있는 것만 공유한다:
//   - MLS 상태·messages.db  → App Group 컨테이너(LiveDependencies.storageDirectory)
//   - 기기 ID               → App Group UserDefaults(앱 전용 standard 에 있던 값은 1회 옮긴다)
//   - 봉인 키·릴레이 자격증명 → Keychain 접근 그룹 = App Group ID(iOS 는 App Group 을 keychain 접근 그룹으로 쓸 수 있다)
// App Group 이 없으면(무서명 시뮬레이터·CI) 모두 앱 전용으로 폴백한다 — 이때 NSE 는 대체 알림만 보인다.
// 비밀값(쿠키·봉인 키)은 Keychain 에만, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`(NSE 가 잠금 화면에서 읽는다), iCloud 동기화 금지.
import Foundation
import FamilyMLSCore
#if canImport(Security)
import Security
#endif

enum SharedStorage {
    /// 열린 App Group 컨테이너. 그룹이 없거나 이 빌드에 권한이 없으면 nil.
    static func appGroupContainer(_ group: String?) -> URL? {
        guard let group, !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    /// 공유 가능한 경우의 Keychain 접근 그룹(= App Group ID). 컨테이너가 안 열리는 빌드에서 그룹을 주면 -34018 이 나므로 nil.
    static func keychainGroup(_ group: String?) -> String? {
        appGroupContainer(group) == nil ? nil : group
    }

    /// 기기 ID 를 담는 defaults. App Group 이 열리면 그 suite(앱 전용 값을 처음 한 번 옮긴다), 아니면 standard.
    static func defaults(appGroup: String?) -> UserDefaults {
        guard appGroupContainer(appGroup) != nil, let group = appGroup, let shared = UserDefaults(suiteName: group) else {
            return .standard
        }
        let key = DeviceIdentity.defaultsKey
        if shared.string(forKey: key) == nil, let legacy = UserDefaults.standard.string(forKey: key) {
            shared.set(legacy, forKey: key)
        }
        return shared
    }

    /// NSE 용: 기기 ID 를 읽기만 한다(없으면 nil — NSE 가 새 기기를 만들면 안 된다).
    static func existingDeviceId(appGroup: String?) -> DeviceID? {
        defaults(appGroup: appGroup).string(forKey: DeviceIdentity.defaultsKey)
    }
}

// MARK: - 릴레이 자격증명 (CF Access 세션)

protocol CredentialStoring: AnyObject {
    func load() -> RelayCredential?
    func save(_ credential: RelayCredential) throws
    func delete()
}

final class InMemoryCredentialStore: CredentialStoring {
    private var value: RelayCredential?
    init(_ value: RelayCredential? = nil) { self.value = value }
    func load() -> RelayCredential? { value }
    func save(_ credential: RelayCredential) throws { value = credential }
    func delete() { value = nil }
}

/// Keychain 바이트 형식: `cookie\n<jwt>` / `bearer\n<jwt>`(UTF-8). 값은 화면·로그에 내지 않는다.
enum CredentialCoding {
    static func encode(_ credential: RelayCredential) -> Data {
        switch credential {
        case .accessCookie(let jwt): return Data("cookie\n\(jwt)".utf8)
        case .bearer(let jwt): return Data("bearer\n\(jwt)".utf8)
        }
    }

    static func decode(_ data: Data) -> RelayCredential? {
        let text = String(decoding: data, as: UTF8.self)
        guard let split = text.firstIndex(of: "\n") else { return nil }
        let value = String(text[text.index(after: split)...])
        guard !value.isEmpty else { return nil }
        switch text[..<split] {
        case "cookie": return .accessCookie(value)
        case "bearer": return .bearer(value)
        default: return nil
        }
    }
}

#if canImport(Security)
final class KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let account: String
    private let accessGroup: String?

    init(service: String = "familychat.relay-credential", account: String = "v1", accessGroup: String?) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    func load() -> RelayCredential? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return CredentialCoding.decode(data)
    }

    func save(_ credential: RelayCredential) throws {
        let data = CredentialCoding.encode(credential)
        let update = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw StateStoreError.sealing("credential update failed (status \(update))") }
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw StateStoreError.sealing("credential add failed (status \(status))") }
    }

    func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
#endif

extension SharedStorage {
    /// 운영 자격증명 저장소: Keychain(공유 그룹), Keychain 이 없는 플랫폼은 메모리.
    static func credentialStore(appGroup: String?) -> CredentialStoring {
        #if canImport(Security)
        return KeychainCredentialStore(accessGroup: keychainGroup(appGroup))
        #else
        return InMemoryCredentialStore()
        #endif
    }

    /// 운영 봉인: ChaChaPoly + Keychain 키(공유 그룹). Keychain 이 없는 플랫폼은 nil(= Core 기본, Linux Passthrough).
    static func sealer(appGroup: String?) throws -> FileStateSealing? {
        #if canImport(Security)
        return try ChaChaPolySealer(keySource: KeychainSealKeySource(accessGroup: keychainGroup(appGroup)))
        #else
        return nil
        #endif
    }
}
