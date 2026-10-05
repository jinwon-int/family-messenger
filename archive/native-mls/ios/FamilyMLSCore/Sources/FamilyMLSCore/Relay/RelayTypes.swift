// 계약 2 — v2 릴레이 와이어 타입 (CONTRACTS.md §2). `archive/native-mls/server/server.go` 의 구조체와 **필드 이름이 글자 그대로**
// 같다(2026-10-05 main 10a43eb 기준). Go `[]byte` ↔ Swift `Data` 는 둘 다 base64 문자열. 확장 ①②(§2.3)는 L2 가 서버에
// 구현하고, 타입은 여기서 동결한다.
import Foundation

public enum EventKind: String, Codable { case commit, welcome, application }

public struct MemberWire: Codable, Equatable {
    public var device: DeviceID
    public var actor: String
    public init(device: DeviceID, actor: String) { self.device = device; self.actor = actor }
}

/// POST /v2/rooms/{room}/events
public struct EventPost: Codable, Equatable {
    public var device: DeviceID
    public var clientId: String
    public var kind: EventKind
    public var epoch: Int64
    public var revision: Int64?
    public var groupId: String?
    public var targets: [DeviceID]?
    public var members: [MemberWire]?
    public var bytes: Data
    enum CodingKeys: String, CodingKey {
        case device, kind, epoch, revision, targets, members, bytes
        case clientId = "client_id", groupId = "group_id"
    }
    public init(device: DeviceID, clientId: String, kind: EventKind, epoch: Int64, revision: Int64? = nil, groupId: String? = nil, targets: [DeviceID]? = nil, members: [MemberWire]? = nil, bytes: Data) {
        self.device = device; self.clientId = clientId; self.kind = kind; self.epoch = epoch; self.revision = revision
        self.groupId = groupId; self.targets = targets; self.members = members; self.bytes = bytes
    }
}

public struct EventPostResponse: Codable, Equatable {
    public var seq: Int64
    public var epoch: Int64
    public var revision: Int64
    /// 200 + duplicate=true: 같은 (room, device, client_id) 의 정확 바이트 재전송(K4).
    public var duplicate: Bool
}

public struct StoredEvent: Codable, Equatable {
    public var seq: Int64
    public var device: DeviceID
    public var clientId: String
    public var kind: EventKind
    public var epoch: Int64
    public var bytes: Data
    public var sha256: String
    public var createdAt: Int64
    enum CodingKeys: String, CodingKey { case seq, device, kind, epoch, bytes, sha256; case clientId = "client_id", createdAt = "created_at" }
}

/// GET /v2/rooms/{room}/events?device=&after=&limit=&ack=
public struct EventsPage: Codable, Equatable {
    public var epoch: Int64
    public var revision: Int64
    public var events: [StoredEvent]
    public var nextAfter: Int64
    public var cursor: Int64?
    /// 보존된 가장 오래된 seq. `firstSeq > cursor + 1` 이면 이력 공백 → 재참여 안내(#268 과 같은 판정).
    public var firstSeq: Int64?
    public var members: [MemberWire]?
    enum CodingKeys: String, CodingKey { case epoch, revision, events, cursor, members; case nextAfter = "next_after", firstSeq = "first_seq" }
}

public struct KeyPackageInput: Codable, Equatable {
    public var ref: String      // sha256 hex of bytes (봇 규칙)
    public var bytes: Data
    public init(ref: String, bytes: Data) { self.ref = ref; self.bytes = bytes }
}

/// POST /v2/rooms/{room}/keypackages
public struct KeyPackagePost: Codable, Equatable {
    public var device: DeviceID
    public var packages: [KeyPackageInput]
    public init(device: DeviceID, packages: [KeyPackageInput]) { self.device = device; self.packages = packages }
}

public struct KeyPackagesResponse: Codable, Equatable { public var stored: Int; public var duplicates: Int }

/// GET /v2/rooms/{room}/keypackages?device=<소비하는 기기>&target=<상대 기기> — 원자 소비 (정확한 쿼리명은 L3 가 server.go 로 확인·고정)
public struct StoredKeyPackage: Codable, Equatable {
    public var ref: String
    public var bytes: Data
    public var expiresAt: Int64
    enum CodingKeys: String, CodingKey { case ref, bytes; case expiresAt = "expires_at" }
}

/// 오류 바디 `{"error":"<code>", "epoch":N?, "revision":N?}` — cas_mismatch 일 때 현재 값이 실린다.
public struct RelayErrorBody: Codable, Equatable {
    public var error: String
    public var epoch: Int64?
    public var revision: Int64?
}

/// server.go 에 존재하는 오류 코드(2026-10-05). 새 코드는 여기 추가.
public enum RelayErrorCode: String {
    case casMismatch = "cas_mismatch"
    case deviceSubjectMismatch = "device_subject_mismatch"
    case notAMember = "not_a_member"
    case roomClosed = "room_closed"
    case duplicateMember = "duplicate_member"
    case invalidToken = "invalid_token"
}

public enum RelayError: Error, Equatable {
    /// 409 cas_mismatch — `clear_pending` → 동기화 → 새 op 으로 재암호화(옛 op 은 reconciled).
    case cas(epoch: Int64, revision: Int64)
    /// 401 — CF Access 세션 만료/부재 → 재로그인 화면.
    case unauthorized
    /// 403 등 코드가 있는 거부 — device_subject_mismatch(미등록), not_a_member(revoke) 는 ⛔ 정지 또는 등록 대기 상태로.
    case refused(code: String, status: Int)
    case network(String)
    case decoding(String)
}

// MARK: - 확장 ①② (L2 서버 구현 대상; 타입 동결)

/// GET /v2/rooms?device=
public struct RoomListing: Codable, Equatable {
    public var room: RoomID
    public var epoch: Int64
    public var revision: Int64
    public var member: Bool
    public var keypackagesOutstanding: Int
    public var closed: Bool
    enum CodingKeys: String, CodingKey { case room, epoch, revision, member, closed; case keypackagesOutstanding = "keypackages_outstanding" }
}
public struct RoomsResponse: Codable, Equatable { public var rooms: [RoomListing] }

/// POST /v2/push/devices (204) · DELETE /v2/push/devices?device= (204)
public struct PushRegistration: Codable, Equatable {
    public var device: DeviceID
    public var apnsToken: Data
    public var topic: String        // = Bundle ID
    enum CodingKeys: String, CodingKey { case device, topic; case apnsToken = "apns_token" }
    public init(device: DeviceID, apnsToken: Data, topic: String) { self.device = device; self.apnsToken = apnsToken; self.topic = topic }
}

/// APNs 페이로드(릴레이 → Apple → NSE). 평문·암호문·발신자 없음.
public struct PushPayload: Codable, Equatable {
    public var room: RoomID
    public var seq: Int64
}
