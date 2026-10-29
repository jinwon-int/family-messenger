// 옛 설치 이관(#584 PR 2) — 스코프 없는 경로·키·Keychain account 를 빌드 기본 서버(`FC_RELAY_URL`)의 스코프로 **한 번** 옮긴다.
// `LiveDependencies.fromBundle` 이 저장된 선택이 없고 기본값이 있을 때만 부른다. 앱 전용(NSE 는 아무것도 만들거나 옮기지 않는다).
// 키 목록은 `ServerScope.swift` 머리말과 같아야 한다(ServerScopeTests 가 상수로 대조).
import Foundation
import FamilyMLSCore

/// 옛 설치(스코프 없는 경로·키·Keychain account)를 빌드 기본 서버의 스코프로 **한 번** 옮긴다. 옮긴 뒤 옛 자리는 지우므로 다시 돌려도 no-op.
/// 스코프 쪽에 이미 값이 있으면 그 값을 지키고 옛 값은 버리지 않고 남긴다(덮어쓰지 않음).
enum LegacyScopeMigration {
    /// 스코프 없는 자리의 파일·키(옮길 대상 전부).
    static let fileNames = ["mls", "messages.db", "messages.db-wal", "messages.db-shm", "messages.db-journal"]
    /// App Group defaults(앱·NSE 공유) 키.
    static let sharedKeys = [DeviceIdentity.defaultsKey, DefaultsActorStore.key]
    /// 앱 전용 defaults 키.
    static let localKeys = [UserDefaultsPushRecordStore.key, LocalPrefs.readKey, LocalPrefs.orderKey]

    struct Report: Equatable {
        var movedFiles: [String] = []
        var movedKeys: [String] = []
        var movedCredential = false
        var isEmpty: Bool { movedFiles.isEmpty && movedKeys.isEmpty && !movedCredential }
    }

    /// 옮길 것이 하나라도 있는가(파일·공유 키·앱 전용 키·옛 Keychain 항목).
    static func hasLegacyData(root: URL, shared: UserDefaults, local: UserDefaults, legacyCredentials: CredentialStoring?) -> Bool {
        if fileNames.contains(where: { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) { return true }
        if sharedKeys.contains(where: { shared.object(forKey: $0) != nil }) { return true }
        if localKeys.contains(where: { local.object(forKey: $0) != nil }) { return true }
        return legacyCredentials?.load() != nil
    }

    @discardableResult
    static func run(root: URL, scope: ServerScope, shared: UserDefaults, local: UserDefaults,
                    legacyCredentials: CredentialStoring?, scopedCredentials: CredentialStoring?) -> Report {
        var report = Report()
        let fm = FileManager.default
        let target = scope.directory(in: root)
        for name in fileNames {
            let from = root.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                report.movedFiles.append(name)
            } catch {
                // 옮기지 못한 항목은 남긴다 — 다음 실행이 다시 시도한다(새 자리가 비어 있는 한).
            }
        }
        let sharedScoped = scope.defaults(shared)
        for name in sharedKeys {
            guard let value = shared.object(forKey: name) else { continue }
            if sharedScoped.object(forKey: name) == nil { sharedScoped.set(value, forKey: name) }
            shared.removeObject(forKey: name)
            report.movedKeys.append(name)
        }
        let localScoped = scope.defaults(local)
        for name in localKeys {
            guard let value = local.object(forKey: name) else { continue }
            if localScoped.object(forKey: name) == nil { localScoped.set(value, forKey: name) }
            local.removeObject(forKey: name)
            report.movedKeys.append(name)
        }
        if let legacyCredentials, let scopedCredentials, let credential = legacyCredentials.load() {
            if scopedCredentials.load() == nil, (try? scopedCredentials.save(credential)) != nil {
                legacyCredentials.delete()
                report.movedCredential = true
            } else if scopedCredentials.load() != nil {
                legacyCredentials.delete()
            }
        }
        return report
    }
}
