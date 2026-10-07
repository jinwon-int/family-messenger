// 계약 3.1 — 파일 봉인 (CONTRACTS.md §3.1). **L1 결정: AEAD = CryptoKit `ChaChaPoly` 단일 방식.**
//
// - Apple(iOS 16·macOS 13+): `CryptoKit.ChaChaPoly`(시스템 프레임워크, 의존 추가 없음).
//   nonce 는 매 `seal` 호출마다 시스템 CSPRNG 로 12B 새로 발급된다(ChaChaPoly 기본 동작 —
//   직접 만든 KDF/nonce 규칙 위반 없음, libsodium secretstream 대신 이쪽을 택해 기록한다).
//   키는 Keychain 32B(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, synchronizable=false
//   = iCloud 금지). 파일 보호 `.completeUntilFirstUserAuthentication` 는 파일 생성 측
//   (FileStateStore/FileSQLiteStore)에서 `#if os(iOS)` 로 적용한다.
// - Linux(swift-core-linux): 이 툴체인 이미지에는 CryptoKit 도 CryptoKit 호환 `Crypto` 모듈도
//   없어서(Package.swift 수정 금지로 swift-crypto 추가 불가) 계약이 허용한 두 봉인 모두 컴파일될 수
//   없다. CONTRACTS §0 L1 행이 정한 Linux 검증 범위(flock·원자 영속·SQLite·generation)를 지키기
//   위해 `#if canImport(CryptoKit)` 이 거짓인 플랫폼에서만 `PassthroughSealer`(무봉인 통과)로
//   컴파일된다. Apple 빌드는 항상 ChaChaPoly 경로다 — 이 차이는 PR 본문 "증명하지 않은 것"에 기록한다.
import Foundation

/// `<room>.state` 페이로드 봉인 경계. 파일 헤더(magic+generation)는 평문, 이 프로토콜의 입출력만 봉인 대상이다.
public protocol FileStateSealing: AnyObject {
    var schemeName: String { get }
    /// 평문 → AEAD 프레임(ChaChaPoly combined = nonce 12B ‖ ciphertext ‖ tag 16B).
    func seal(_ plaintext: Data) throws -> Data
    /// AEAD 프레임 → 평문. 인증 실패·프레임 손상은 `StateStoreError.sealing`.
    func open(_ sealed: Data) throws -> Data
}

#if canImport(CryptoKit)
import CryptoKit

/// 운영 봉인(Apple). 키 소스는 `FileSealKeySource` 로 주입(운영 = Keychain, 테스트 = 정적 키).
public final class ChaChaPolySealer: FileStateSealing {
    public let schemeName = "chachapoly"
    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    public convenience init(keySource: FileSealKeySource) throws {
        self.init(key: SymmetricKey(data: try keySource.key32()))
    }

    public func seal(_ plaintext: Data) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key).combined
    }

    public func open(_ sealed: Data) throws -> Data {
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed)
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw StateStoreError.sealing("chachapoly open failed: \(error)")
        }
    }
}
#endif

/// 봉인 키 32B 공급자. 운영(Apple) = `KeychainSealKeySource`, 테스트 = `StaticSealKeySource`.
public protocol FileSealKeySource: AnyObject {
    func key32() throws -> Data
}

/// 테스트·Linux 주입용 고정 키(32B). Apple 운영 경로에서 쓰지 않는다.
public final class StaticSealKeySource: FileSealKeySource {
    private let key: Data

    public init(key: Data) {
        precondition(key.count == 32, "seal key must be 32 bytes")
        self.key = key
    }

    public func key32() throws -> Data { key }
}

#if canImport(Security)
import Security

/// Keychain 32B 봉인 키. 첫 사용에 `SecRandomCopyBytes` 로 생성 후 GenericPassword 로 저장,
/// 이후 읽기만 한다. 두 스토어 인스턴스(App·NSE)가 같은 키를 공유하는 경로다.
/// App 과 NSE 는 앱 ID 가 달라 기본 접근 그룹이 다르다 — 공유하려면 `accessGroup`(App Group ID 또는 keychain-access-groups 항목)을
/// 준다(파이널라이저 §12-D 결정 D8). nil = 기본 그룹(이 프로세스 전용).
public final class KeychainSealKeySource: FileSealKeySource {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(service: String = "fm.mls.state-seal", account: String = "seal-v1", accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func key32() throws -> Data {
        if let existing = try read() { return existing }

        var key = Data(count: 32)
        let rc = key.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }
        guard rc == errSecSuccess else {
            throw StateStoreError.sealing("SecRandomCopyBytes failed (\(rc))")
        }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        var withGroup = add
        if let accessGroup { withGroup[kSecAttrAccessGroup as String] = accessGroup }
        let addStatus = SecItemAdd(withGroup as CFDictionary, nil)
        if addStatus == errSecDuplicateItem, let raced = try read() {
            return raced   // 다른 프로세스(App·NSE)가 같은 순간 먼저 만들었다 — 그 키를 쓴다
        }
        guard addStatus == errSecSuccess else {
            throw StateStoreError.sealing("keychain add failed (status \(addStatus))")
        }
        return key
    }

    private func read() throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else {
            throw StateStoreError.sealing("keychain read failed (status \(status))")
        }
        return nil
    }
}
#endif

#if !canImport(CryptoKit)
/// 무봉인 통과 — `canImport(CryptoKit)` 이 거짓인 플랫폼(Linux CI)에서만 존재·선택된다.
/// Linux CI 가 검증하는 것은 잠금·원자 영속·generation 기계(CONTRACTS §0 L1)다.
public final class PassthroughSealer: FileStateSealing {
    public let schemeName = "passthrough(no-cryptokit)"
    public init() {}
    public func seal(_ plaintext: Data) throws -> Data { plaintext }
    public func open(_ sealed: Data) throws -> Data { sealed }
}
#endif

/// 플랫폼 기본 봉인: Apple = ChaChaPoly + Keychain 키, 그 외(Linux CI) = Passthrough.
public func defaultFileSealer() throws -> FileStateSealing {
    #if canImport(CryptoKit)
    return try ChaChaPolySealer(keySource: KeychainSealKeySource())
    #else
    return PassthroughSealer()
    #endif
}
