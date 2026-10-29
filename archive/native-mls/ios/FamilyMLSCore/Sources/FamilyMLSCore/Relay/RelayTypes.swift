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
    /// #562(server/typing.go): 이 방에서 지금 글을 쓰는 **다른** 기기(요청 기기 제외, 정렬, 만료 TTL 6s). 옛 릴레이는 싣지 않는다(nil).
    public var typing: [DeviceID]?
    /// #571 B(server/read.go): 요청 기기와 **같은 사람(actor)** 의 어느 기기든 본 가장 큰 seq(`POST /read`). 없으면 0. 옛 릴레이는 싣지 않는다(nil).
    public var readSeq: Int64?
    enum CodingKeys: String, CodingKey {
        case epoch, revision, events, cursor, members, typing
        case nextAfter = "next_after", firstSeq = "first_seq", readSeq = "read_seq"
    }
}

/// POST /v2/rooms/{room}/typing(#562, server/typing.go `typingPost`) → 204. `clear` = 입력을 멈췄다(신호 삭제).
public struct TypingPost: Codable, Equatable {
    public var device: DeviceID
    public var clear: Bool
    public init(device: DeviceID, clear: Bool) { self.device = device; self.clear = clear }
}

/// POST /v2/rooms/{room}/read(#571 B, server/read.go `readPost`) → 200 `ReadResponse`. `seq` = 이 기기가 이 방을 여기까지 봤다(0..last_seq).
public struct ReadPost: Codable, Equatable {
    public var device: DeviceID
    public var seq: Int64
    public init(device: DeviceID, seq: Int64) { self.device = device; self.seq = seq }
}

/// `POST /read` 응답 `{read_seq}` — 요청 뒤 같은 사람(actor)의 읽음 위치. 올린 값보다 클 수 있다(다른 기기가 더 멀리 봤다). 줄어들지 않는다.
public struct ReadResponse: Codable, Equatable {
    public var readSeq: Int64
    enum CodingKeys: String, CodingKey { case readSeq = "read_seq" }
    public init(readSeq: Int64) { self.readSeq = readSeq }
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

/// 응답 `{stored, duplicates, live}` — `live`(게시 뒤 이 기기의 미소비 수)는 #381 릴레이부터 실린다(옛 릴레이는 없음 → nil).
public struct KeyPackagesResponse: Codable, Equatable {
    public var stored: Int
    public var duplicates: Int
    public var live: Int?
    public init(stored: Int, duplicates: Int, live: Int? = nil) { self.stored = stored; self.duplicates = duplicates; self.live = live }
}

/// GET /v2/rooms/{room}/keypackages?device=<패키지 소유 기기>&consumer=<소비하는 나> — 원자 소비(server.go handleConsumeKeyPackage, CONTRACTS §2.1)
public struct StoredKeyPackage: Codable, Equatable {
    public var ref: String
    public var bytes: Data
    public var expiresAt: Int64
    enum CodingKeys: String, CodingKey { case ref, bytes; case expiresAt = "expires_at" }
}

/// 오류 바디 `{"error":"<code>", "epoch":N?, "revision":N?, "detail":…?}` — cas_mismatch 일 때 현재 값이, 기기 셀프서비스(#574)의
/// 409 `stale_revision` 에는 현재 정책 `revision`, 403 `approval_rejected` 에는 사유 `detail` 이 실린다.
public struct RelayErrorBody: Codable, Equatable {
    public var error: String
    public var epoch: Int64?
    public var revision: Int64?
    public var detail: String?
}

/// 기기 셀프서비스 라우트(#574, server/devices.go)의 정책 거부 — 본문의 `detail`·`revision` 을 호출자가 써야 하는 둘만 이 타입으로
/// 던진다(`URLSessionRelayTransport.deviceRouteFailure`): 409 `stale_revision`(`revision` = 현재 → 그 값으로 한 번 다시 서명),
/// 403 `approval_rejected`(`detail` = 서명·서명자 규칙 위반 사유). 그 밖은 다른 라우트와 같이 `RelayError`.
public struct DevicePolicyRefusal: Error, Equatable {
    public var code: String
    public var status: Int
    public var detail: String?
    public var revision: Int64?
    public init(code: String, status: Int, detail: String? = nil, revision: Int64? = nil) {
        self.code = code; self.status = status; self.detail = detail; self.revision = revision
    }
}

/// server.go 에 존재하는 오류 코드(2026-10-05). 새 코드는 여기 추가.
public enum RelayErrorCode: String {
    case casMismatch = "cas_mismatch"
    case deviceSubjectMismatch = "device_subject_mismatch"
    case notAMember = "not_a_member"
    case roomClosed = "room_closed"
    case duplicateMember = "duplicate_member"
    case invalidToken = "invalid_token"
    // 로비(server/lobby.go, #380 P5-1)
    /// 정책 체인이 켜진 릴레이에서 아직 등록되지 않은 기기의 로비 게시·소비 — 등록 대기와 같이 다룬다.
    case deviceNotAllowed = "device_not_allowed"
    /// 기기당 미소비 상한(기본 8) 초과 — 서버에 이미 충분히 있다.
    case keyPackageLimit = "key_package_limit"
    case noLiveKeyPackage = "no_live_key_package"
    // 기기 셀프서비스(server/devices.go, #574)
    /// 후보 게시: 이 기기 ID 는 이미 체인에 있다(ID 는 재사용 불가) — 새 ID 로 다시 시작해야 한다.
    case deviceExists = "device_exists"
    /// 후보 게시: 호출자(subject)에게 활성 기기가 없다 — 첫 기기는 운영자 대역외 등록(E1).
    case firstDeviceOutOfBand = "first_device_out_of_band"
    /// 승인·역할: 서명한 base_revision 이 현재가 아니다(`revision` = 현재 → 한 번 다시 서명).
    case staleRevision = "stale_revision"
    /// 승인·역할: 서명·서명자 규칙 위반(`detail` 에 사유 — registrar 아님, 마지막 registrar 등).
    case approvalRejected = "approval_rejected"
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

// MARK: - 로비 key package (#380 P5-1, server/lobby.go — 필드 이름 글자 그대로)

/// GET /v2/lobby/status?device= — 이 기기의 미소비 로비 키 수와 정책 상한·만료(앱의 보충 판단).
public struct LobbyStatus: Codable, Equatable {
    public var device: DeviceID
    public var live: Int
    public var max: Int
    public var ttlSeconds: Int64
    enum CodingKeys: String, CodingKey { case device, live, max; case ttlSeconds = "ttl_seconds" }
    public init(device: DeviceID, live: Int, max: Int, ttlSeconds: Int64) {
        self.device = device; self.live = live; self.max = max; self.ttlSeconds = ttlSeconds
    }
}

/// GET /v2/lobby/welcomes?device= 의 한 행: 이 기기를 대상으로 한 Welcome 이 있고 이 기기의 영속 커서가 아직 지나지 않은 열린 방.
/// 본문은 그 방의 `GET /events` 로 읽는다(여기에는 포인터만).
public struct PendingWelcome: Codable, Equatable, Hashable {
    public var room: RoomID
    public var seq: Int64
    public var epoch: Int64
    public var createdAt: Int64
    /// 이 방에서 소비된 이 기기의 로비 key package `ref`(sha256 hex) — 아직 참여하지 않은 Welcome 의 비밀을 보충이 지우지 않게
    /// (`LobbyKeyring.replenish(protect:)`, #518). 옛 릴레이는 싣지 않는다(nil) · 빈 문자열일 수 있다 → "모름" 으로 다룬다.
    public var keyPackageRef: String?
    /// 이 Welcome 을 올린 기기(#574, lobby.go `From`) — 같은 actor 의 활성 형제 기기가 보낸 초대는 묻지 않고 받는다(`SelfService.isSibling`).
    /// 옛 릴레이는 싣지 않는다(nil → 형제 아님).
    public var from: DeviceID?
    enum CodingKeys: String, CodingKey { case room, seq, epoch, from; case createdAt = "created_at", keyPackageRef = "key_package_ref" }
    public init(room: RoomID, seq: Int64, epoch: Int64, createdAt: Int64, keyPackageRef: String? = nil, from: DeviceID? = nil) {
        self.room = room; self.seq = seq; self.epoch = epoch; self.createdAt = createdAt; self.keyPackageRef = keyPackageRef; self.from = from
    }
}
/// DELETE /v2/lobby/keypackages 응답(#389, lobby.go `lobbyDeleteResponse`).
public struct LobbyDeleteResponse: Codable, Equatable {
    public var device: DeviceID
    public var deleted: Int
    public init(device: DeviceID, deleted: Int) { self.device = device; self.deleted = deleted }
}

public struct LobbyWelcomes: Codable, Equatable {
    public var welcomes: [PendingWelcome]
    public init(welcomes: [PendingWelcome]) { self.welcomes = welcomes }
}

// MARK: - 기기 셀프서비스 (#574 D1, server/devices.go · me.go — 필드 이름 글자 그대로)

/// POST /v2/devices/candidates 본문(strict JSON) — 새 기기(아직 체인에 없음)가 자기 공개 기록을 우편함에 올린다. `subject` 는 넣지 않는다
/// (릴레이가 JWT 에서 읽는다). `fingerprint` 는 선택이지만 보내면 서버가 signing_key 와 대조한다.
public struct DeviceCandidatePost: Codable, Equatable {
    public var deviceId: DeviceID
    public var actor: String
    public var signingKey: String
    public var fingerprint: String
    enum CodingKeys: String, CodingKey { case actor, fingerprint; case deviceId = "device_id", signingKey = "signing_key" }
    public init(deviceId: DeviceID, actor: String, signingKey: String, fingerprint: String) {
        self.deviceId = deviceId; self.actor = actor; self.signingKey = signingKey; self.fingerprint = fingerprint
    }
    public init(_ registration: EnrollmentRequest) {
        self.init(deviceId: registration.deviceId, actor: registration.actor, signingKey: registration.signingKey, fingerprint: registration.fingerprint)
    }
}

/// 201 `{device_id, fingerprint, policy_revision, expires_at}` — `expires_at` 은 Unix 초(TTL 10분; 만료 5분 전에 다시 올린다).
public struct DeviceCandidatePosted: Codable, Equatable {
    public var deviceId: DeviceID
    public var fingerprint: String
    public var policyRevision: Int64
    public var expiresAt: Int64
    enum CodingKeys: String, CodingKey { case fingerprint; case deviceId = "device_id", policyRevision = "policy_revision", expiresAt = "expires_at" }
    public init(deviceId: DeviceID, fingerprint: String, policyRevision: Int64, expiresAt: Int64) {
        self.deviceId = deviceId; self.fingerprint = fingerprint; self.policyRevision = policyRevision; self.expiresAt = expiresAt
    }
}

/// GET /v2/devices/candidates 의 한 행(`candidateView`) — 공개 값만(서명 **공개** 키·지문).
public struct DeviceCandidate: Codable, Equatable, Hashable {
    public var deviceId: DeviceID
    public var actor: String
    public var subject: String
    public var signingKey: String
    public var fingerprint: String
    public var createdAt: Int64
    public var expiresAt: Int64
    enum CodingKeys: String, CodingKey {
        case actor, subject, fingerprint
        case deviceId = "device_id", signingKey = "signing_key", createdAt = "created_at", expiresAt = "expires_at"
    }
    public init(deviceId: DeviceID, actor: String, subject: String, signingKey: String, fingerprint: String, createdAt: Int64, expiresAt: Int64) {
        self.deviceId = deviceId; self.actor = actor; self.subject = subject; self.signingKey = signingKey
        self.fingerprint = fingerprint; self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}

/// GET /v2/devices/candidates?device= → `{policy_revision, candidates}` — `policy_revision` 이 승인 서명의 `base_revision`.
public struct DeviceCandidates: Codable, Equatable {
    public var policyRevision: Int64
    public var candidates: [DeviceCandidate]
    enum CodingKeys: String, CodingKey { case candidates; case policyRevision = "policy_revision" }
    public init(policyRevision: Int64, candidates: [DeviceCandidate]) { self.policyRevision = policyRevision; self.candidates = candidates }
}

/// POST /v2/devices/approvals 본문 = `devicepolicy.AddDeviceEvidence`(CLI `-add-device` 입력, strict JSON — `action`·`acceptance` 는 없다).
public struct DeviceApprovalEvidence: Codable, Equatable {
    public var deviceId: DeviceID
    public var actor: String
    public var subject: String
    public var signingKey: String
    public var baseRevision: Int64
    /// Ed25519 서명 lowercase hex(128자) — `sign_approval` 프레임의 마지막 64바이트.
    public var signature: String
    public var fingerprint: String
    public var approvedBy: DeviceID
    enum CodingKeys: String, CodingKey {
        case actor, subject, signature, fingerprint
        case deviceId = "device_id", signingKey = "signing_key", baseRevision = "base_revision", approvedBy = "approved_by"
    }
    public init(deviceId: DeviceID, actor: String, subject: String, signingKey: String, baseRevision: Int64, signature: String, fingerprint: String, approvedBy: DeviceID) {
        self.deviceId = deviceId; self.actor = actor; self.subject = subject; self.signingKey = signingKey
        self.baseRevision = baseRevision; self.signature = signature; self.fingerprint = fingerprint; self.approvedBy = approvedBy
    }
}

/// POST /v2/devices/roles 본문 = `devicepolicy.RolesEvidence`(E5) — `roles` 는 대상이 갖게 될 **완전한 정렬 목록**(빈 배열 = 역할 없음).
public struct DeviceRolesEvidence: Codable, Equatable {
    public var deviceId: DeviceID
    public var actor: String
    public var roles: [String]
    public var baseRevision: Int64
    public var signature: String
    public var approvedBy: DeviceID
    enum CodingKeys: String, CodingKey { case actor, roles, signature; case deviceId = "device_id", baseRevision = "base_revision", approvedBy = "approved_by" }
    public init(deviceId: DeviceID, actor: String, roles: [String], baseRevision: Int64, signature: String, approvedBy: DeviceID) {
        self.deviceId = deviceId; self.actor = actor; self.roles = roles; self.baseRevision = baseRevision; self.signature = signature; self.approvedBy = approvedBy
    }
}

/// 승인·역할 201 `{device_id, approved_by, revision[, roles]}` — 체인 commit 뒤의 새 revision.
public struct DevicePolicyCommit: Codable, Equatable {
    public var deviceId: DeviceID
    public var approvedBy: DeviceID
    public var revision: Int64
    public var roles: [String]?
    enum CodingKeys: String, CodingKey { case revision, roles; case deviceId = "device_id", approvedBy = "approved_by" }
    public init(deviceId: DeviceID, approvedBy: DeviceID, revision: Int64, roles: [String]? = nil) {
        self.deviceId = deviceId; self.approvedBy = approvedBy; self.revision = revision; self.roles = roles
    }
}

/// GET /v2/me 의 `devices[]` 한 행(me.go `meDevice`) — 호출자 subject 의 체인 기록(폐기 포함), 서명 키 없음.
public struct MeDevice: Codable, Equatable, Hashable {
    public var deviceId: DeviceID
    public var actor: String
    public var fingerprint: String
    /// `active` · `revoked`.
    public var status: String
    public var acceptance: String
    public var roles: [String]
    enum CodingKeys: String, CodingKey { case actor, fingerprint, status, acceptance, roles; case deviceId = "device_id" }
    public init(deviceId: DeviceID, actor: String, fingerprint: String, status: String, acceptance: String, roles: [String]) {
        self.deviceId = deviceId; self.actor = actor; self.fingerprint = fingerprint; self.status = status; self.acceptance = acceptance; self.roles = roles
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(DeviceID.self, forKey: .deviceId)
        actor = try c.decode(String.self, forKey: .actor)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        acceptance = try c.decodeIfPresent(String.self, forKey: .acceptance) ?? ""
        roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? []   // 서버는 항상 배열을 쓰지만(null 금지) 방어적으로
    }
}

/// GET /v2/me → `{subject[, policy_revision, devices]}`. 기기 저장소가 없는 옛 릴레이는 `subject` 만(둘 다 nil).
public struct MeResponse: Codable, Equatable {
    public var subject: String
    public var policyRevision: Int64?
    public var devices: [MeDevice]?
    enum CodingKeys: String, CodingKey { case subject, devices; case policyRevision = "policy_revision" }
    public init(subject: String, policyRevision: Int64? = nil, devices: [MeDevice]? = nil) {
        self.subject = subject; self.policyRevision = policyRevision; self.devices = devices
    }
}
