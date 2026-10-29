// 새 기기 셀프서비스(#574 PR 3) — 순수 판정·조립 함수(엔진·릴레이·화면 없음). 웹 `web/hande/self-service.js` 와 같은 결정을 Swift 로.
//
// 서버 계약(PR #578, server/devices.go · me.go · lobby.go):
//   POST /v2/devices/candidates  새 기기가 자기 공개 기록을 우편함에 올린다(subject 는 JWT 에서, 본문에 넣지 않는다).
//   GET  /v2/devices/candidates  같은 subject 의 활성 기기가 우편함을 본다 → {policy_revision, candidates}.
//   POST /v2/devices/approvals   E2 증거(approve-device 서명) → 체인 commit. 409 stale_revision 이면 revision 으로 다시 서명.
//   POST /v2/devices/roles       E5 증거(set-roles 서명, roles 는 완전한 정렬 목록) → registrar 부여/해제.
//   GET  /v2/me                  {subject, policy_revision, devices:[{device_id, actor, fingerprint, status, acceptance, roles}]}.
// 누가 서명할 수 있나(devicepolicy.VerifyApproval/VerifyRoles): 이 기기가 활성이고, (registrar 이거나 같은 actor 에 활성 registrar 가 하나도 없을 때).
// 마지막 registrar 는 스스로 해제할 수 없다(다른 기기에 먼저 부여).
import Foundation

public enum SelfService {
    public static let roleRegistrar = "registrar"
    public static let approvalAction = "approve-device"
    public static let approvalAcceptance = "trusted-device-fingerprint"
    /// 형제 기기 초대 대기열의 수명 — 새 기기가 활성이 된 뒤 로비 키를 올릴 때까지 기다리되, 영원히는 아니다.
    public static let siblingInviteTTL: TimeInterval = 30 * 60
    /// 후보 게시의 재게시 여유: 만료(10분) 이만큼 전에 다시 올린다.
    public static let candidateRepostMargin: TimeInterval = 5 * 60
    public static let statusActive = "active"

    public enum Failure: Error, Equatable {
        /// `base_revision` 이 없거나 1 미만 — /v2/me 나 후보 목록이 revision 을 주지 않았다(옛 릴레이).
        case baseRevision
        /// 파사드 출력이 `u32le n ‖ canonical(n) ‖ 64바이트 서명` 이 아니다.
        case signatureFrame
    }

    // MARK: - /v2/me 읽기

    private static func devices(_ me: MeResponse?) -> [MeDevice] { me?.devices ?? [] }
    private static func isActive(_ d: MeDevice) -> Bool { d.status == statusActive }
    public static func isRegistrar(_ d: MeDevice) -> Bool { d.roles.contains(roleRegistrar) }

    /// /v2/me 의 그 기기 기록(없으면 nil — 옛 릴레이거나 아직 체인에 없는 기기).
    public static func record(of me: MeResponse?, device: DeviceID) -> MeDevice? {
        devices(me).first { $0.deviceId == device }
    }

    /// 이 actor 에 활성 registrar 가 하나라도 있나(devicepolicy.HasRegistrar).
    public static func actorHasRegistrar(_ me: MeResponse?, actor: String) -> Bool {
        devices(me).contains { $0.actor == actor && isActive($0) && isRegistrar($0) }
    }

    /// 이 기기가 같은 actor 의 새 기기를 승인(E2)하거나 역할(E5)에 서명할 수 있나:
    /// 활성이고, registrar 이거나 그 actor 에 활성 registrar 가 없다(#574 이전 체인의 「활성 기기면 누구나」 규칙).
    public static func canApprove(_ me: MeResponse?, device: DeviceID) -> Bool {
        guard let rec = record(of: me, device: device), isActive(rec) else { return false }
        return isRegistrar(rec) || !actorHasRegistrar(me, actor: rec.actor)
    }

    /// 로비 Welcome 을 보낸 기기가 내 형제 기기인가 — 내가 아니고, 체인에 그 ID 의 활성 기록이 있고, 같은 actor.
    /// 오너가 아닌 가족도 자기 다른 기기가 보낸 초대는 묻지 않고 받는다. 옛 릴레이(from 없음)는 false.
    public static func isSibling(from: DeviceID?, me: MeResponse?, actor: String?, device: DeviceID) -> Bool {
        guard let from, !from.isEmpty, from != device, let actor, !actor.isEmpty,
              let rec = record(of: me, device: from) else { return false }
        return rec.actor == actor && isActive(rec)
    }

    // MARK: - 후보 · 승인(E2)

    private static func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// 우편함에서 내 actor 의 후보만(모양이 온전한 것만). 승인은 같은 actor 사이에서만 유효하다.
    public static func candidates(in list: DeviceCandidates?, actor: String) -> [DeviceCandidate] {
        (list?.candidates ?? []).filter { !$0.deviceId.isEmpty && $0.actor == actor && isHex64($0.signingKey) && isHex64($0.fingerprint) }
    }

    /// `sign_approval` 입력(파사드가 받는 정확한 키 집합 — 알 수 없는 키는 거부된다).
    public struct ApprovalArgs: Codable, Equatable {
        public var action: String
        public var deviceId: DeviceID
        public var actor: String
        public var subject: String
        public var signingKey: String
        public var acceptance: String
        public var baseRevision: Int64
        enum CodingKeys: String, CodingKey {
            case action, actor, subject, acceptance
            case deviceId = "device_id", signingKey = "signing_key", baseRevision = "base_revision"
        }
    }

    public static func approvalArgs(_ candidate: DeviceCandidate, baseRevision: Int64?) throws -> ApprovalArgs {
        guard let base = baseRevision, base >= 1 else { throw Failure.baseRevision }
        return ApprovalArgs(action: approvalAction, deviceId: candidate.deviceId, actor: candidate.actor, subject: candidate.subject,
                            signingKey: candidate.signingKey, acceptance: approvalAcceptance, baseRevision: base)
    }

    /// POST /v2/devices/approvals 본문 = AddDeviceEvidence(strict JSON): action·acceptance 는 뺀다.
    public static func approvalEvidence(_ args: ApprovalArgs, signature: String, fingerprint: String, approvedBy: DeviceID) -> DeviceApprovalEvidence {
        DeviceApprovalEvidence(deviceId: args.deviceId, actor: args.actor, subject: args.subject, signingKey: args.signingKey,
                               baseRevision: args.baseRevision, signature: signature, fingerprint: fingerprint, approvedBy: approvedBy)
    }

    // MARK: - 역할(E5)

    /// 역할 목록에 registrar 를 넣거나 빼서 **완전한 정렬 목록**으로(서버 CanonicalRoles 와 같은 모양 — 중복 없음).
    public static func nextRoles(_ roles: [String], grant: Bool) -> [String] {
        var set = Set(roles)
        if grant { set.insert(roleRegistrar) } else { set.remove(roleRegistrar) }
        return set.sorted()
    }

    /// `sign_roles` 입력 `{device_id, actor, roles, base_revision}`.
    public struct RolesArgs: Codable, Equatable {
        public var deviceId: DeviceID
        public var actor: String
        public var roles: [String]
        public var baseRevision: Int64
        enum CodingKeys: String, CodingKey { case actor, roles; case deviceId = "device_id", baseRevision = "base_revision" }
    }

    public static func rolesArgs(_ target: MeDevice, roles: [String], baseRevision: Int64?) throws -> RolesArgs {
        guard let base = baseRevision, base >= 1 else { throw Failure.baseRevision }
        return RolesArgs(deviceId: target.deviceId, actor: target.actor, roles: Array(Set(roles)).sorted(), baseRevision: base)
    }

    /// POST /v2/devices/roles 본문 = RolesEvidence.
    public static func rolesEvidence(_ args: RolesArgs, signature: String, approvedBy: DeviceID) -> DeviceRolesEvidence {
        DeviceRolesEvidence(deviceId: args.deviceId, actor: args.actor, roles: args.roles, baseRevision: args.baseRevision,
                            signature: signature, approvedBy: approvedBy)
    }

    /// 「내 기기」 화면의 행: 체인의 내 subject 기기 전부(폐기 포함) + 이 기기가 각 기기에 할 수 있는 역할 변경.
    public struct DeviceRow: Equatable, Identifiable {
        public var deviceId: DeviceID
        public var actor: String
        public var fingerprint: String
        public var status: String
        public var roles: [String]
        public var registrar: Bool
        public var isSelf: Bool
        /// registrar 를 부여할 수 있다(대상이 활성·같은 actor·아직 registrar 아님).
        public var grant: Bool
        /// registrar 를 해제할 수 있다(대상이 활성·같은 actor·registrar 이고 해제 뒤에도 활성 registrar 가 남을 때).
        public var release: Bool
        /// 해제하면 registrar 가 없어진다 — 다른 기기에 먼저 부여.
        public var lastRegistrar: Bool
        public var id: DeviceID { deviceId }
    }

    public struct RolesView: Equatable {
        /// 이 기기가 E5 에 서명할 수 있나(= canApprove).
        public var canSign: Bool
        public var actor: String?
        public var devices: [DeviceRow]
        public static let empty = RolesView(canSign: false, actor: nil, devices: [])
    }

    /// - 서명 가능 = canApprove(E5 도 같은 규칙: 활성 + registrar 이거나 actor 에 registrar 없음).
    /// - 부여: 대상이 활성·같은 actor·아직 registrar 가 아닐 때. 해제: 대상이 활성·같은 actor·registrar 이고 해제 뒤에도 활성 registrar 가 남을 때.
    public static func rolesActions(_ me: MeResponse?, device: DeviceID) -> RolesView {
        let all = devices(me)
        let selfRecord = record(of: me, device: device)
        let canSign = canApprove(me, device: device)
        let actor = selfRecord?.actor
        let activeRegistrars = all.filter { $0.actor == actor && isActive($0) && isRegistrar($0) }.count
        let rows = all.map { d -> DeviceRow in
            let registrar = isRegistrar(d)
            let eligible = canSign && isActive(d) && d.actor == actor
            let release = eligible && registrar && activeRegistrars - 1 > 0
            return DeviceRow(deviceId: d.deviceId, actor: d.actor, fingerprint: d.fingerprint, status: d.status, roles: d.roles, registrar: registrar,
                             isSelf: d.deviceId == device, grant: eligible && !registrar, release: release, lastRegistrar: eligible && registrar && !release)
        }
        return RolesView(canSign: canSign, actor: actor, devices: rows)
    }

    // MARK: - 형제 기기 초대

    /// 한 방의 초대 판정 입력(웹 `roomsView()` 와 같은 모양).
    public struct RoomView: Equatable {
        public var roomId: RoomID
        public var joined: Bool
        public var halted: Bool
        /// 내 commit 이 대기 중(epoch 가 움직이는 중) — 다음 바퀴에.
        public var pending: Bool
        /// 현재 명단(모르면 nil = 명단 검사 없음).
        public var roster: [DeviceID]?
        public init(roomId: RoomID, joined: Bool, halted: Bool, pending: Bool, roster: [DeviceID]?) {
            self.roomId = roomId; self.joined = joined; self.halted = halted; self.pending = pending; self.roster = roster
        }
    }

    /// 새 형제 기기를 초대할 방: 내가 참여했고, 정지가 아니고, 내 commit 이 대기 중이 아니고, 아직 명단에 없는 방.
    public static func siblingInviteRooms(_ rooms: [RoomView], target: DeviceID) -> [RoomID] {
        rooms.filter { $0.joined && !$0.halted && !$0.pending && !($0.roster?.contains(target) ?? false) }.map(\.roomId)
    }

    // MARK: - 등록 화면 모드

    /// POST /v2/devices/candidates 의 결과 → 등록 화면 모드. 201 = 형제 기기가 승인한다(`sibling`); 409 device_exists = 이 ID 는 다시 쓸 수 없다
    /// (`idTaken`); 403 first_device_out_of_band·subject_mismatch, 404(옛 릴레이·접근 인증 꺼짐), 그 밖 = 운영자 흐름(`operator`).
    public enum EnrollMode: Equatable {
        case operatorFlow, sibling, idTaken
    }

    public static func enrollMode(afterPost error: Error?) -> EnrollMode {
        guard let error else { return .sibling }
        if case RelayError.refused(let code, let status) = error, status == 409, code == RelayErrorCode.deviceExists.rawValue { return .idTaken }
        return .operatorFlow
    }

    // MARK: - 파사드 프레임 · 표시

    /// 파사드 출력 `u32le(n) ‖ canonical payload(n바이트) ‖ Ed25519 서명(64)` → 서명 lowercase hex(128자). 웹 `signatureOf` 와 동일.
    public static func signatureHex(framed: Data) throws -> String {
        guard framed.count >= 4 else { throw Failure.signatureFrame }
        let n = framed.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let start = framed.startIndex + 4 + n
        guard start <= framed.endIndex, framed.endIndex - start == 64 else { throw Failure.signatureFrame }
        return framed[start..<framed.endIndex].map { String(format: "%02x", $0) }.joined()
    }

    /// 지문을 눈으로 한 자리씩 비교하기 쉽게 4자씩 띄운다(웹 `groupFingerprint`). 공백은 먼저 지운다.
    public static func fingerprintGroups(_ hex: String) -> String {
        let clean = hex.filter { !$0.isWhitespace }
        var groups: [String] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let end = clean.index(index, offsetBy: 4, limitedBy: clean.endIndex) ?? clean.endIndex
            groups.append(String(clean[index..<end]))
            index = end
        }
        return groups.joined(separator: " ")
    }
}

// MARK: - 형제 기기 초대 대기열

/// 새 기기는 활성이 된 다음 틱에야 로비 키를 올리므로 승인 직후의 초대는 「키 패키지 없음」으로 실패한다. 승인한 기기가 방 목록을 적어 두고
/// 바퀴마다 다시 시도한다; TTL 이 지나면 🔔 에 알리고 버린다. 웹 `hande:sibling-invites:<device>` 와 같은 뜻(여기서는 UserDefaults).
public struct SiblingInviteQueue: Equatable {
    public struct Entry: Codable, Equatable {
        public var target: DeviceID
        public var rooms: [RoomID]
        /// 처음 넣은 시각(Unix 초).
        public var since: TimeInterval
        public init(target: DeviceID, rooms: [RoomID], since: TimeInterval) { self.target = target; self.rooms = rooms; self.since = since }
    }

    public var entries: [Entry]
    public init(_ entries: [Entry] = []) { self.entries = entries }
    public var isEmpty: Bool { entries.isEmpty }

    /// (target, rooms) 를 넣는다 — 같은 target 이 있으면 방을 합치고 시각은 유지. 방이 없으면 그대로.
    public func enqueued(target: DeviceID, rooms: [RoomID], now: Date) -> SiblingInviteQueue {
        var add: [RoomID] = []
        for room in rooms where !room.isEmpty && !add.contains(room) { add.append(room) }
        guard !add.isEmpty else { return self }
        var next = entries
        if let index = next.firstIndex(where: { $0.target == target }) {
            for room in add where !next[index].rooms.contains(room) { next[index].rooms.append(room) }
        } else {
            next.append(Entry(target: target, rooms: add, since: now.timeIntervalSince1970))
        }
        return SiblingInviteQueue(next)
    }

    /// 처리할 것과 포기할 것(TTL 지남)으로 나눈다.
    public func split(now: Date, ttl: TimeInterval = SelfService.siblingInviteTTL) -> (live: [Entry], expired: [Entry]) {
        var live: [Entry] = [], expired: [Entry] = []
        for e in entries { if now.timeIntervalSince1970 - e.since > ttl { expired.append(e) } else { live.append(e) } }
        return (live, expired)
    }
}

/// 대기열 영속(기기별). 앱은 UserDefaults, 테스트는 메모리.
public protocol SiblingQueueStoring: AnyObject {
    func load(device: DeviceID) -> SiblingInviteQueue
    func save(_ queue: SiblingInviteQueue, device: DeviceID)
}

public final class InMemorySiblingQueueStore: SiblingQueueStoring {
    private var queues: [DeviceID: SiblingInviteQueue] = [:]
    public init() {}
    public func load(device: DeviceID) -> SiblingInviteQueue { queues[device] ?? SiblingInviteQueue() }
    public func save(_ queue: SiblingInviteQueue, device: DeviceID) { queues[device] = queue.isEmpty ? nil : queue }
}

/// `hande.siblingInvites.<device>` 키에 JSON 배열. 깨진 값은 빈 대기열, 비면 키를 지운다(웹과 동일).
public final class UserDefaultsSiblingQueueStore: SiblingQueueStoring {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    public static func key(_ device: DeviceID) -> String { "hande.siblingInvites.\(device)" }

    public func load(device: DeviceID) -> SiblingInviteQueue {
        guard let data = defaults.data(forKey: Self.key(device)),
              let entries = try? JSONDecoder().decode([SiblingInviteQueue.Entry].self, from: data) else { return SiblingInviteQueue() }
        return SiblingInviteQueue(entries.filter { !$0.target.isEmpty })
    }

    public func save(_ queue: SiblingInviteQueue, device: DeviceID) {
        if queue.isEmpty { defaults.removeObject(forKey: Self.key(device)); return }
        if let data = try? JSONEncoder().encode(queue.entries) { defaults.set(data, forKey: Self.key(device)) }
    }
}
