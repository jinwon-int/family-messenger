// 서버별 네임스페이스(#584 PR 2) — 서버를 바꿔도 기기 상태·자격증명·표시 설정이 섞이지 않게 모든 로컬 저장 경로를 한 곳에서 스코프한다.
//
//   id = sha256(정규화한 base URL) 앞 8바이트 hex(16자). 정규화 = 스킴·host 소문자, 포트, 끝 `/` 없는 경로.
//   - 파일: `<base>/servers/<id>/{mls/, messages.db}`               (`directory(in:)`)
//   - App Group UserDefaults: `<키>.<id>`  — 기기 ID·사용자 이름        (`defaults(_:)` → `ScopedDefaults`)
//   - 앱 전용 UserDefaults: `<키>.<id>`     — 푸시 등록 기록·읽음 위치·방 순서
//   - Keychain 자격증명: service `familychat.relay-credential`, account `v1.<id>`   (`keychainAccount`)
//   스코프하지 않는 것: 봉인 키(`fm.mls.state-seal`/`seal-v1` — 파일 보호 키, 대화 비밀 아님, NSE 와 공유) ·
//   형제 기기 초대 대기열(`hande.siblingInvites.<device>` — 기기 ID 가 스코프마다 새로 나므로 이미 분리) · `hande.server` 자체.
// 옛 설치(스코프 없는 경로)는 `LegacyScopeMigration`(별도 파일, 앱 전용)이 빌드 기본 서버의 스코프로 한 번 옮긴다.
// NSE 소스 목록(project.yml)에 들어간다 — UIKit·SwiftUI 의존 금지. Linux 스모크는 대역 CryptoKit(SHA256 식별용)으로 컴파일한다.
import Foundation
import CryptoKit
import FamilyMLSCore

struct ServerScope: Equatable {
    let id: String

    init(baseURL: URL) {
        let digest = SHA256.hash(data: Data(Self.canonical(baseURL).utf8))
        id = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `https://Relay.Example.com/` 와 `https://relay.example.com` 은 같은 서버.
    static func canonical(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let scheme = (components.scheme ?? "https").lowercased()
        let host = (components.host ?? "").lowercased()
        let port = components.port.map { ":\($0)" } ?? ""
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(port)\(path)"
    }

    static let directoryName = "servers"

    /// `<base>/servers/<id>` — MLS 상태·messages.db 가 이 아래에.
    func directory(in base: URL) -> URL {
        base.appendingPathComponent(Self.directoryName, isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    func key(_ base: String) -> String { "\(base).\(id)" }

    /// Keychain 자격증명 account(옛 설치는 `v1`).
    var keychainAccount: String { "v1.\(id)" }
    static let legacyKeychainAccount = "v1"

    func defaults(_ base: UserDefaults) -> ScopedDefaults { ScopedDefaults(base, scope: self) }
}

/// UserDefaults 의 키 앞에 스코프를 붙이는 얇은 겉면. `scope == nil` = 옛 설치의 스코프 없는 키(이관·테스트).
final class ScopedDefaults {
    let base: UserDefaults
    let scope: ServerScope?

    init(_ base: UserDefaults, scope: ServerScope? = nil) {
        self.base = base
        self.scope = scope
    }

    func key(_ name: String) -> String { scope?.key(name) ?? name }

    func string(forKey name: String) -> String? { base.string(forKey: key(name)) }
    func data(forKey name: String) -> Data? { base.data(forKey: key(name)) }
    func stringArray(forKey name: String) -> [String]? { base.stringArray(forKey: key(name)) }
    func dictionary(forKey name: String) -> [String: Any]? { base.dictionary(forKey: key(name)) }
    func object(forKey name: String) -> Any? { base.object(forKey: key(name)) }
    func set(_ value: Any?, forKey name: String) { base.set(value, forKey: key(name)) }
    func removeObject(forKey name: String) { base.removeObject(forKey: key(name)) }
}
