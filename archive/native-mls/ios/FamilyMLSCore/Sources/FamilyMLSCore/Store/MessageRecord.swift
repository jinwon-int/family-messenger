// 계약 4 — 복호화 결과 보관 (CONTRACTS.md §4, #271 §4 `messages.db`). MLS 는 같은 메시지를 다시 복호화할 수 없으므로
// NSE 든 앱이든 복호화한 쪽이 여기에 쓰고, 화면은 여기서만 읽는다. L1 이 SQLite 로 구현, 스키마는 아래 DDL 로 동결.
import Foundation

public struct MessageRecord: Equatable {
    /// `fileV2`(#499): 분리 첨부 — body = mime 표시 힌트(없으면 빈 문자열, 신뢰하지 않음), attachment = 검증한 설명자 JSON(파일 키 포함 —
    /// 글로 보이거나 공유하지 않는다). 저장 값 `file-v2` 는 웹·안드로이드 이력과 같은 말. 모르는 값은 읽을 때 `.system`.
    public enum Kind: String {
        case text, attachment, undecryptable, system
        case fileV2 = "file-v2"
        /// 첨부(v1 본체 또는 v2 설명자)인가 — 미리보기 문구·대화 요약에서 「사진」으로 다룬다.
        public var isFile: Bool { self == .attachment || self == .fileV2 }
    }
    public enum DecryptedBy: String { case app, nse }
    public let room: RoomID
    public let seq: Int64
    public let senderDevice: DeviceID
    /// 첫 `-` 앞 = actor (relay-app 규칙).
    public var senderActor: String { String(senderDevice.split(separator: "-", maxSplits: 1).first ?? Substring(senderDevice)) }
    /// 기기 ID 의 actor(첫 `-` 앞, 없으면 ID 전체).
    public static func actor(of device: DeviceID) -> String { String(device.split(separator: "-", maxSplits: 1).first ?? Substring(device)) }
    /// 내 글인가 — 같은 사람(actor)이면 **다른 기기에서 보낸 글도 내 글**(오너 결정 2026-10-20: PC 에서 쓴 말이 iPhone 에서도 오른쪽).
    /// 빈 기기 ID 는 아무것도 내 글이 아니다.
    public func isMine(device: DeviceID) -> Bool { !device.isEmpty && senderActor == MessageRecord.actor(of: device) }
    public let clientId: String
    public let kind: Kind
    /// text: 본문 / attachment: 파일명 등 표시 메타 / undecryptable: 사유(키 없음)
    public let body: String
    /// attachment 본체(≤256 KiB) — 별도 파일로 둘지 blob 으로 둘지는 L1 결정(계약은 "같은 Data Protection" 만).
    public let attachment: Data?
    /// 메시지 시각(#405): 동기화로 받은 글 = 릴레이 기록 시각(`created_at`), 내가 보낸 글 = 보낸 순간. 화면 시간 표시의 기준.
    /// (이름은 처음 뜻을 남겨 둔다 — 그 전에 저장된 행은 복호화한 순간이다.)
    public let receivedAt: Date
    public let decryptedBy: DecryptedBy
    public init(room: RoomID, seq: Int64, senderDevice: DeviceID, clientId: String, kind: Kind, body: String, attachment: Data?, receivedAt: Date, decryptedBy: DecryptedBy) {
        self.room = room; self.seq = seq; self.senderDevice = senderDevice; self.clientId = clientId; self.kind = kind
        self.body = body; self.attachment = attachment; self.receivedAt = receivedAt; self.decryptedBy = decryptedBy
    }
}

public struct RoomRecord: Equatable {
    public let room: RoomID
    public var epoch: Int64
    public var revision: Int64
    /// ⛔ 정지 사유(commit 정책 위반·403·이력 공백). nil = 정상. 새로고침·재시작 뒤에도 유지(relay-app localStorage 상당).
    public var haltedReason: String?
    public var displayOrder: Int
    public init(room: RoomID, epoch: Int64, revision: Int64, haltedReason: String?, displayOrder: Int) {
        self.room = room; self.epoch = epoch; self.revision = revision; self.haltedReason = haltedReason; self.displayOrder = displayOrder
    }
}

public protocol MessageStore: AnyObject {
    func insert(_ record: MessageRecord) throws
    func messages(room: RoomID, after seq: Int64, limit: Int) throws -> [MessageRecord]
    func upsertRoom(_ room: RoomRecord) throws
    func rooms() throws -> [RoomRecord]
    func setHalted(room: RoomID, reason: String?) throws
}

public enum MessageSchema {
    /// 동결 스키마 v1. 바꾸려면 `schema_version` 을 올리고 마이그레이션을 쓴다(파사드 record 코덱과 같은 규율).
    public static let version = 1
    public static let ddl = """
    CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS rooms (
      room TEXT PRIMARY KEY,
      epoch INTEGER NOT NULL DEFAULT 0,
      revision INTEGER NOT NULL DEFAULT 0,
      halted_reason TEXT,
      display_order INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS messages (
      room TEXT NOT NULL,
      seq INTEGER NOT NULL,
      sender_device TEXT NOT NULL,
      client_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      body TEXT NOT NULL,
      attachment BLOB,
      received_at REAL NOT NULL,
      decrypted_by TEXT NOT NULL,
      PRIMARY KEY (room, seq)
    );
    CREATE TABLE IF NOT EXISTS outbox (
      room TEXT NOT NULL,
      client_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      epoch INTEGER NOT NULL,
      bytes BLOB NOT NULL,
      sha256 TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at REAL NOT NULL,
      PRIMARY KEY (room, client_id)
    );
    CREATE TABLE IF NOT EXISTS cursors (room TEXT PRIMARY KEY, seq INTEGER NOT NULL);
    """
}
