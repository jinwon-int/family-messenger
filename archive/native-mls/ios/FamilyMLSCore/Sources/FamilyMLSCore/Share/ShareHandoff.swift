// 공유 확장 → 앱 맡김(#643 1단계). 확장은 MLS·Keychain·FFI 를 링크하지 않고 내용과 고른 방을 App Group 컨테이너에
// **맡기기만** 한다(결정 D1 — 단축어 송신과 같은 원칙: 송신은 앱 프로세스의 같은 모델로만, `AppModel.sendFromShortcut`).
// 앱이 시작·전면 복귀·공유 알림 탭 때 꺼내 화면 송신과 같은 경로로 보낸다(`AppModel.deliverPendingShares`).
//
// 디스크 형식(D2) — `<App Group>/share-outbox/`:
//   .staging-<epoch초>-<id>/   확장이 쓰는 중(파일 → item.json 순서). 다 쓰면 디렉터리째 `<id>/` 로 rename(원자).
//   <id>/item.json             완성된 맡김. 보이는 디렉터리는 언제나 완성본이다.
//   <id>/claimed.json          앱이 가져갔다(item.json 을 rename — 두 경로가 동시에 집어도 한 번만 성공).
//   <id>/<n>-<이름>             내용 파일(순서 = n).
// claim 된 채 남은 디렉터리(송신 중 앱 종료)는 다시 보내지 않고 버린다(`discardStaleClaims`) — 중복 송신보다 드문 유실이 낫다.
// 24시간이 지난 맡김·다른 서버 스코프의 맡김은 만료 때 정리한다(다른 스코프는 그 전까지 보존 — 서버를 되돌리면 보낸다).
//
// 파일 크기는 리소스 값(`fileSizeKey`)으로만 읽고 파일 시각 API 는 쓰지 않는다(Required Reason 범주를 늘리지 않음, 시각은 item.json 의
// `createdAt`·staging 이름의 epoch). Foundation 만 쓴다 — Linux `swift test`.
import Foundation

public enum ShareHandoff {
    public static let directoryName = "share-outbox"
    /// 서버 스코프 defaults 키 — 앱이 공유할 수 있는 방 ID 를 목록 화면 순서로 써 두고 확장이 읽는다(D3).
    public static let targetsKey = "hande.shareTargets"
    /// 공유 알림 userInfo 키(값 = 맡김 ID). 방은 푸시와 같은 `room` 키로 함께 싣는다 — 탭하면 기존 규칙대로 그 방이 열린다.
    public static let notificationKey = "hande.share"
    /// 첨부 개수 상한(D5).
    public static let maxAttachments = 10
    /// 맡김 수명 — 이보다 오래된 것은 보내지 않고 지운다(오래된 공유가 뒤늦게 튀어나오지 않게).
    public static let lifetime: TimeInterval = 24 * 60 * 60
    /// 쓰다 만 staging 을 다른 프로세스가 지워도 되는 나이(확장이 아직 쓰는 중일 수 있으므로 넉넉히).
    public static let stagingLifetime: TimeInterval = 60 * 60

    /// 파일 1개 한도 — 앱의 송신 경로(`AppModel.sendAttachment`)와 같은 값.
    public static func maxFileBytes(fileV2: Bool = FileV2Format.sendDefault) -> Int {
        fileV2 ? FileV2Format.maxFileBytes : AttachmentFormat.maxBytes
    }

    /// 공유 대상: 목록 화면과 같은 순서(`RoomOrder.apply`)에서 정지된 방을 뺀 ID.
    public static func targets(_ rooms: [RoomRecord], saved: [RoomID]) -> [RoomID] {
        RoomOrder.apply(rooms, saved: saved).filter { $0.haltedReason == nil }.map(\.room)
    }

    /// 공유받은 글 조각과 링크를 한 글로(앞뒤 공백 제거, 빈 조각·중복 링크 제외, 줄바꿈으로 잇기). 비면 nil.
    public static func composeText(_ texts: [String], urls: [URL]) -> String? {
        var parts: [String] = []
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !parts.contains(trimmed) { parts.append(trimmed) }
        }
        for url in urls {
            let value = url.absoluteString
            // Safari 는 제목 글에 주소를 함께 싣기도 한다 — 이미 들어 있으면 다시 붙이지 않는다.
            if !parts.contains(where: { $0.contains(value) }) { parts.append(value) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    public struct Item: Codable, Equatable {
        public static let currentVersion = 1
        public var version: Int
        public var id: String
        public var createdAt: Date
        /// 서버 스코프 ID(`ServerScope.id`) — 앱은 지금 스코프의 맡김만 보낸다.
        public var scope: String
        public var room: RoomID
        public var text: String?
        /// 디렉터리 안 내용 파일 이름(보낼 순서).
        public var files: [String]

        public init(id: String, createdAt: Date, scope: String, room: RoomID, text: String?, files: [String]) {
            self.version = Self.currentVersion
            self.id = id; self.createdAt = createdAt; self.scope = scope; self.room = room; self.text = text; self.files = files
        }
    }

    public enum Failure: Error, Equatable {
        case empty
        case tooManyAttachments(count: Int, limit: Int)
        case fileTooLarge(name: String, bytes: Int, limit: Int)
        case unreadable(name: String)
    }
}

/// 맡김 저장소(확장 = `commit`, 앱 = `pending`·`claim`·`finish`·`discardStaleClaims`).
public final class ShareHandoffStore {
    public let root: URL
    private let fileManager = FileManager.default
    private static let itemFile = "item.json"
    private static let claimedFile = "claimed.json"
    private static let stagingPrefix = ".staging-"

    /// `container` = App Group 컨테이너(테스트는 임시 디렉터리). 맡김은 그 아래 `share-outbox/`.
    public init(container: URL) {
        self.root = container.appendingPathComponent(ShareHandoff.directoryName, isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 파일 크기(바이트) — 리소스 값으로만 읽는다(파일 시각 API 아님). 못 읽으면 nil.
    public static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// 보내기 전 검증(확장 화면이 먼저 보여 주고, `commit` 이 다시 막는다).
    public static func validate(text: String?, files: [URL], maxFileBytes: Int) throws {
        let hasText = !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || !files.isEmpty else { throw ShareHandoff.Failure.empty }
        guard files.count <= ShareHandoff.maxAttachments else {
            throw ShareHandoff.Failure.tooManyAttachments(count: files.count, limit: ShareHandoff.maxAttachments)
        }
        for file in files {
            guard let bytes = fileSize(file) else { throw ShareHandoff.Failure.unreadable(name: file.lastPathComponent) }
            guard (1...maxFileBytes).contains(bytes) else {
                throw ShareHandoff.Failure.fileTooLarge(name: file.lastPathComponent, bytes: bytes, limit: maxFileBytes)
            }
        }
    }

    /// 확장: 파일을 staging 에 복사하고 item.json 을 쓴 뒤 디렉터리째 `<id>/` 로 옮긴다. 성공하면 앱이 볼 수 있다.
    @discardableResult
    public func commit(scope: String, room: RoomID, text: String?, files: [URL], maxFileBytes: Int = ShareHandoff.maxFileBytes(),
                       now: Date = Date(), id: String = UUID().uuidString) throws -> ShareHandoff.Item {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try Self.validate(text: body, files: files, maxFileBytes: maxFileBytes)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("\(Self.stagingPrefix)\(Int(now.timeIntervalSince1970))-\(id)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            var names: [String] = []
            for (index, file) in files.enumerated() {
                let name = "\(index)-\(Self.safeName(file.lastPathComponent))"
                try fileManager.copyItem(at: file, to: staging.appendingPathComponent(name))
                names.append(name)
            }
            let item = ShareHandoff.Item(id: id, createdAt: now, scope: scope, room: room, text: body, files: names)
            try Self.encoder.encode(item).write(to: staging.appendingPathComponent(Self.itemFile), options: .atomic)
            try fileManager.moveItem(at: staging, to: root.appendingPathComponent(id, isDirectory: true))
            return item
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// 앱: 이 스코프의 완성된 맡김(생성 순). 그러면서 만료(24h)·깨진 맡김·오래된 staging 을 지운다.
    /// claim 된 디렉터리는 건드리지 않는다(같은 프로세스가 보내는 중일 수 있다 — 남은 것은 `discardStaleClaims`).
    public func pending(scope: String, now: Date = Date()) -> [ShareHandoff.Item] {
        var out: [ShareHandoff.Item] = []
        for entry in entries() {
            let name = entry.lastPathComponent
            if name.hasPrefix(Self.stagingPrefix) {
                if let started = Self.stagingEpoch(name), now.timeIntervalSince1970 - started > ShareHandoff.stagingLifetime {
                    try? fileManager.removeItem(at: entry)
                }
                continue
            }
            let itemURL = entry.appendingPathComponent(Self.itemFile)
            guard fileManager.fileExists(atPath: itemURL.path) else { continue }   // claim 됐거나(보내는 중) 다른 이름의 찌꺼기
            guard let data = try? Data(contentsOf: itemURL),
                  let item = try? Self.decoder.decode(ShareHandoff.Item.self, from: data),
                  item.version == ShareHandoff.Item.currentVersion, item.id == name else {
                try? fileManager.removeItem(at: entry)   // 읽을 수 없는 맡김은 보낼 수도 없다
                continue
            }
            if now.timeIntervalSince(item.createdAt) > ShareHandoff.lifetime {
                try? fileManager.removeItem(at: entry)
                continue
            }
            if item.scope == scope { out.append(item) }
        }
        return out.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// 앱: 보내기 직전에 가져간다(item.json → claimed.json, 원자 rename). 이미 누가 가져갔으면 nil.
    public func claim(_ id: String) -> ShareHandoff.Item? {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let claimed = directory.appendingPathComponent(Self.claimedFile)
        do {
            try fileManager.moveItem(at: directory.appendingPathComponent(Self.itemFile), to: claimed)
        } catch {
            return nil
        }
        guard let data = try? Data(contentsOf: claimed), let item = try? Self.decoder.decode(ShareHandoff.Item.self, from: data) else {
            try? fileManager.removeItem(at: directory)
            return nil
        }
        return item
    }

    /// 맡김 안 내용 파일 경로.
    public func fileURL(_ item: ShareHandoff.Item, _ name: String) -> URL {
        root.appendingPathComponent(item.id, isDirectory: true).appendingPathComponent(name)
    }

    /// 앱: 보냈다(또는 보낼 수 없어 버린다) — 디렉터리째 지운다.
    public func finish(_ id: String) {
        try? fileManager.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
    }

    /// 앱 시작 때 한 번: claim 된 채 남은 디렉터리(지난 실행이 보내는 중에 죽음)를 다시 보내지 않고 지운다. 지운 수.
    @discardableResult
    public func discardStaleClaims() -> Int {
        var removed = 0
        for entry in entries() where !entry.lastPathComponent.hasPrefix(Self.stagingPrefix) {
            if fileManager.fileExists(atPath: entry.appendingPathComponent(Self.claimedFile).path) {
                try? fileManager.removeItem(at: entry)
                removed += 1
            }
        }
        return removed
    }

    private func entries() -> [URL] {
        (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }

    private static func stagingEpoch(_ name: String) -> TimeInterval? {
        let rest = name.dropFirst(stagingPrefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return TimeInterval(rest[rest.startIndex..<dash])
    }

    /// 디렉터리 안 파일 이름: 경로 구분자·제어 문자를 지우고 길이를 줄인다(원래 확장자는 남긴다). 비면 "file".
    static func safeName(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" }
            .map(Character.init))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        guard !cleaned.isEmpty else { return "file" }
        guard cleaned.count > 80 else { return cleaned }
        // 확장자(마지막 점 뒤, 16자 이하)는 남기고 앞부분을 줄인다 — NSString 브리징 없이(Linux).
        if let dot = cleaned.lastIndex(of: "."), dot != cleaned.startIndex {
            let ext = cleaned[cleaned.index(after: dot)...]
            if !ext.isEmpty, ext.count <= 16 {
                return String(cleaned[..<dot].prefix(80 - ext.count - 1)) + "." + ext
            }
        }
        return String(cleaned.prefix(80))
    }
}
