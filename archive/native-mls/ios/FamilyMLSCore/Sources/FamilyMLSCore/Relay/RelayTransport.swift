// 계약 2 — 릴레이 전송 경계 (CONTRACTS.md §2). **레인 L3 이 URLSession + CF Access 쿠키로 구현한다.**
// 인증 방식(A: WKWebView 쿠키 / B: 서비스 토큰)은 `RelayCredential` 뒤에 숨긴다. Core 의 동기화 로직은 이 프로토콜만 본다.
import Foundation

public enum RelayCredential: Equatable {
    /// `Cookie: CF_Authorization=<jwt>` — 엣지가 `Cf-Access-Jwt-Assertion` 을 주입(#271 §6-A).
    case accessCookie(String)
    /// `Cf-Access-Jwt-Assertion: <jwt>` 직접(봇 레인·툴링 폴백, server/auth.go).
    case bearer(String)
}

public protocol RelayTransport: AnyObject {
    func postKeyPackages(room: RoomID, _ post: KeyPackagePost) async throws -> KeyPackagesResponse
    /// 상대 기기의 키 패키지 1개를 원자 소비. 없으면 nil.
    func consumeKeyPackage(room: RoomID, device: DeviceID, target: DeviceID) async throws -> StoredKeyPackage?
    func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse
    func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage
    func closeRoom(room: RoomID, device: DeviceID) async throws
    // 확장 ①② — L2 가 서버에 넣기 전에는 `.refused(code:"not_found", status:404)` 를 던진다.
    func listRooms(device: DeviceID) async throws -> RoomsResponse
    func registerPush(_ registration: PushRegistration) async throws
    func unregisterPush(device: DeviceID) async throws

    // 로비 key package(#380 P5-1, server/lobby.go) — 방 무관 풀. 기본 구현은 `.refused(code:"not_found", status:404)`
    // (옛 릴레이·옛 테스트 대역) — 호출자(LobbyKeyring·AppModel)는 404 를 "로비 없음" 으로 보고 건너뛴다.
    /// POST /v2/lobby/keypackages — 이 기기의 로비 키 게시(기기당 live 상한, 만료 TTL).
    func postLobbyKeyPackages(_ post: KeyPackagePost) async throws -> KeyPackagesResponse
    /// GET /v2/lobby/keypackages?device=<상대>&consumer=<나>&room= — 상대의 가장 오래된 로비 키 1개를 `room` 용으로 원자 소비. 없으면 nil.
    func consumeLobbyKeyPackage(device: DeviceID, target: DeviceID, room: RoomID) async throws -> StoredKeyPackage?
    /// GET /v2/lobby/status?device=
    func lobbyStatus(device: DeviceID) async throws -> LobbyStatus
    /// GET /v2/lobby/welcomes?device=
    func lobbyWelcomes(device: DeviceID) async throws -> [PendingWelcome]
    /// DELETE /v2/lobby/keypackages?device= — 이 기기의 미소비 로비 키를 거둔다(#389, 「이 기기 지우기」 직전). 지운 개수.
    func deleteLobbyKeyPackages(device: DeviceID) async throws -> Int

    /// GET /v2/rooms/{room}/blobs/{id}?device= — file-v2 암호문 blob(#499, server/blobs.go, FILE-V2.md §4-3). 원시 바이트.
    /// 403 `not_a_member` · 404 `no_such_blob`(보존 기간 지남) · 410 `room_closed`. 기본 구현은 `.refused(code:"not_found", status:404)`.
    func getBlob(room: RoomID, device: DeviceID, id: String) async throws -> Data
    /// POST /v2/rooms/{room}/blobs?device= — file-v2 암호문 업로드(#499 3단계, FILE-V2.md §3-2). 내용 주소라 멱등:
    /// 201(새로 저장)·200(이미 있음). 413 `blob_too_large`·`room_bytes_cap`·`device_bytes_cap` · 403 · 410 은 `.refused`.
    /// 기본 구현은 `.refused(code:"not_found", status:404)`.
    func postBlob(room: RoomID, device: DeviceID, bytes: Data) async throws -> BlobUpload

    /// POST /v2/rooms/{room}/typing `{device, clear}` → 204(#562, server/typing.go). 이 기기가 글을 쓰는 중(clear = 멈춤)을 다른 멤버의
    /// 다음 `GET /events` 의 `typing` 에 싣는다. 404 `no_such_room` · 410 `room_closed` · 403 `device_not_allowed`/`not_a_member` · 400.
    /// 기본 구현은 `.refused(code:"not_found", status:404)`(라우트 없는 옛 릴레이·옛 테스트 대역) — 호출자(AppModel)는 404 를 보면 그만둔다.
    func postTyping(room: RoomID, device: DeviceID, clear: Bool) async throws

    /// POST /v2/rooms/{room}/read `{device, seq}` → 200 `{read_seq}`(#571 B, server/read.go). 이 기기가 이 방을 `seq` 까지 봤다 — 릴레이는
    /// 같은 사람(actor)의 기기들에 한 값(max, 줄어들지 않음)을 두고 다음 `GET /events` 의 `read_seq` 에 싣는다. 반환 = 요청 뒤 actor 의
    /// 읽음 위치(올린 값보다 클 수 있다). 404 `no_such_room` · 410 `room_closed` · 403 `device_not_allowed`/`not_a_member` · 400 `bad_seq`.
    /// 기본 구현은 `.refused(code:"not_found", status:404)`(라우트 없는 옛 릴레이·옛 테스트 대역) — 호출자(AppModel)는 404 를 보면 그만둔다.
    func postRead(room: RoomID, device: DeviceID, seq: Int64) async throws -> Int64

    /// POST /v2/rooms/{room}/mute `{device, muted}` → 200 `{muted}`(server/mute.go). 같은 사람(actor)의 모든 기기에 한 값 — 릴레이는 꺼진
    /// 사람의 기기에 이 방 새 글 APNs 알림을 보내지 않고, 다음 `GET /events` 의 `muted` 에 싣는다. 반환 = 요청 뒤 값.
    /// 404 `no_such_room` · 410 `room_closed` · 403 `device_not_allowed`/`not_a_member` · 400.
    /// 기본 구현은 `.refused(code:"not_found", status:404)`(라우트 없는 옛 릴레이·옛 테스트 대역).
    func postMute(room: RoomID, device: DeviceID, muted: Bool) async throws -> Bool

    // 기기 셀프서비스(#574 D1, server/devices.go · me.go) — 새 기기가 후보를 올리고 같은 사람의 다른 기기가 승인(E2)·역할(E5)을 서명한다.
    // 기본 구현은 `.refused(code:"not_found", status:404)`(라우트 없는 옛 릴레이·옛 테스트 대역) — 호출자(AppModel)는 404 를 보면 운영자 흐름으로.
    /// POST /v2/devices/candidates `{device_id, actor, signing_key, fingerprint}` → 201. 409 `device_exists` · 403 `first_device_out_of_band`.
    func postDeviceCandidate(_ post: DeviceCandidatePost) async throws -> DeviceCandidatePosted
    /// GET /v2/devices/candidates?device=<나> → `{policy_revision, candidates}`(같은 subject 의 활성 기기만, 403 그 밖).
    func listDeviceCandidates(device: DeviceID) async throws -> DeviceCandidates
    /// POST /v2/devices/approvals(E2 증거) → 201. 409 `stale_revision`·403 `approval_rejected` 는 `DevicePolicyRefusal` 로 던진다.
    func postDeviceApproval(_ evidence: DeviceApprovalEvidence) async throws -> DevicePolicyCommit
    /// POST /v2/devices/roles(E5 증거) → 201. 거부 매핑은 승인과 같다.
    func postDeviceRoles(_ evidence: DeviceRolesEvidence) async throws -> DevicePolicyCommit
    /// GET /v2/me → `{subject[, policy_revision, devices]}`(옛 릴레이는 subject 만). 404 = 접근 인증이 꺼진 릴레이.
    func me() async throws -> MeResponse
}

/// blob 업로드 응답(server/blobs.go `blobResponse`). `created` = 201(새로 저장), false = 200(이미 있음).
public struct BlobUpload: Equatable, Decodable {
    public let id: String
    public let size: Int64
    public var created: Bool = false
    enum CodingKeys: String, CodingKey { case id, size }
    public init(id: String, size: Int64, created: Bool) { self.id = id; self.size = size; self.created = created }
}

public extension RelayTransport {
    func postLobbyKeyPackages(_ post: KeyPackagePost) async throws -> KeyPackagesResponse {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func consumeLobbyKeyPackage(device: DeviceID, target: DeviceID, room: RoomID) async throws -> StoredKeyPackage? {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func lobbyStatus(device: DeviceID) async throws -> LobbyStatus {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func lobbyWelcomes(device: DeviceID) async throws -> [PendingWelcome] {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func deleteLobbyKeyPackages(device: DeviceID) async throws -> Int {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func getBlob(room: RoomID, device: DeviceID, id: String) async throws -> Data {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func postBlob(room: RoomID, device: DeviceID, bytes: Data) async throws -> BlobUpload {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func postTyping(room: RoomID, device: DeviceID, clear: Bool) async throws {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func postRead(room: RoomID, device: DeviceID, seq: Int64) async throws -> Int64 {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func postMute(room: RoomID, device: DeviceID, muted: Bool) async throws -> Bool {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func postDeviceCandidate(_ post: DeviceCandidatePost) async throws -> DeviceCandidatePosted {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func listDeviceCandidates(device: DeviceID) async throws -> DeviceCandidates {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func postDeviceApproval(_ evidence: DeviceApprovalEvidence) async throws -> DevicePolicyCommit {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func postDeviceRoles(_ evidence: DeviceRolesEvidence) async throws -> DevicePolicyCommit {
        throw RelayError.refused(code: "not_found", status: 404)
    }
    func me() async throws -> MeResponse {
        throw RelayError.refused(code: "not_found", status: 404)
    }
}
