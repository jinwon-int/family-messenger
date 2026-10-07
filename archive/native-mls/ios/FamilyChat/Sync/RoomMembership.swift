// 방 참여·생성·초대 — L3 범위 밖으로 남은 "키 패키지 발행·내 commit 생성" 흐름(#317 증명하지 않은 것 4번)을
// relay-app §2·Python 스모크 `add()` 와 같은 순서로 잇는다. 엔진 연산·상태 저장은 방 트랜잭션 안, 네트워크는 밖(CONTRACTS §3.4).
//
//   참여 요청: 트랜잭션 { key_package → save } → POST keypackages(ref = sha256 hex)
//   방 만들기: 트랜잭션 { create → save } (릴레이 방은 첫 commit 이 만든다)
//   초대:      동기화 → KP 소비(?device=<대상>&consumer=<나>) → 트랜잭션 { invite_with_commit → members_after_pending → save }
//              → commit POST(members = 커밋 뒤 roster, CAS = 현재 epoch) → 동기화(내 echo 에서 merge_pending)
//              → Welcome POST(targets=[대상]). commit POST 가 실패하면 clear_pending 으로 되돌린다.
//
// 상태 시드는 `SeededEngineFactory`(D2) — 방 상태가 없으면 identity 슬롯 바이트에서 시작한다.
// `RoomSyncEngine` 은 generation 이 바뀐 것을 보고 다음 트랜잭션에서 다시 import 하므로, 같은 방을 여기서 써도 안전하다.
import CryptoKit
import Foundation
import FamilyMLSCore

enum MembershipError: Error, Equatable {
    /// 대상 기기가 이 방에 게시한 키 패키지가 없다(아직 '참여 요청' 전이거나 이미 소비됨).
    case noKeyPackage(DeviceID)
    /// 이미 그룹이 있는 방 상태에 `create` 를 하려 했다.
    case alreadyInGroup
    /// 초대하려면 먼저 그룹 멤버여야 한다.
    case notInGroup
    /// commit 을 올렸는데 동기화 뒤에도 내 echo 를 만나지 못했다(대기 commit 이 남음).
    case ownCommitNotMerged
    /// `invite_with_commit` 출력이 `u32le commitLen‖commit‖welcome` 이 아니다.
    case inviteFrame
}

final class RoomMembership {
    let room: RoomID
    let identity: DeviceID
    private let engineFactory: MlsEngineFactory
    private let stateStore: MlsStateStore
    private let transport: RelayTransport
    private let lockTimeout: TimeInterval

    init(room: RoomID, identity: DeviceID, engineFactory: MlsEngineFactory, stateStore: MlsStateStore,
         transport: RelayTransport, lockTimeout: TimeInterval = 5) {
        self.room = room; self.identity = identity; self.engineFactory = engineFactory
        self.stateStore = stateStore; self.transport = transport; self.lockTimeout = lockTimeout
    }

    /// 트랜잭션: load(없으면 시드) → body → save. body 가 throw 하면 디스크 불변.
    private func transaction<T>(_ body: (MlsEngine) throws -> T) throws -> T {
        try stateStore.withExclusive(room: room, timeout: lockTimeout) { tx in
            let engine = try tx.load().map { try engineFactory.importState(identity: identity, bytes: $0) }
                ?? engineFactory.create(identity: identity)
            let result = try body(engine)
            try tx.save(try engine.exportState())
            return result
        }
    }

    private static func isMember(_ engine: MlsEngine, _ identity: DeviceID) -> Bool {
        guard let frame = try? engine.dispatch(.members, Data()) else { return false }   // 그룹 없음 = .rejected
        return CommitPolicy.parseRosterFrame(frame)?.contains { $0.id == identity } ?? false
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func clientId(_ label: String) -> String {
        "\(identity)-\(label)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// 참여 요청: 이 방 상태에 키 패키지를 만들고(개인 init 키는 이 방 상태에만) 릴레이에 게시한다.
    @discardableResult
    func publishKeyPackage() async throws -> KeyPackagesResponse {
        let package = try transaction { try $0.dispatch(.keyPackage, Data()) }
        return try await transport.postKeyPackages(room: room, KeyPackagePost(
            device: identity, packages: [KeyPackageInput(ref: Self.sha256Hex(package), bytes: package)]))
    }

    /// 방 만들기(로컬 그룹 생성). 릴레이의 방은 첫 commit(첫 초대)이 만든다.
    func createGroup() throws {
        try transaction { engine in
            if Self.isMember(engine, identity) { throw MembershipError.alreadyInGroup }
            _ = try engine.dispatch(.create, Data())
        }
    }

    /// `target` 기기를 초대한다. 성공하면 commit·Welcome 이 릴레이에 있고 내 그룹은 새 epoch 다.
    func invite(target: DeviceID, sync: RoomSyncEngine) async throws {
        try await sync.syncAll()
        guard let package = try await transport.consumeKeyPackage(room: room, device: identity, target: target) else {
            throw MembershipError.noKeyPackage(target)
        }
        let (commit, welcome, roster) = try transaction { engine -> (Data, Data, [String]) in
            guard Self.isMember(engine, identity) else { throw MembershipError.notInGroup }
            let framed = try engine.dispatch(.inviteWithCommit, package.bytes)
            guard framed.count >= 4 else { throw MembershipError.inviteFrame }
            let length = framed.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            guard framed.count >= 4 + length else { throw MembershipError.inviteFrame }
            let start = framed.startIndex
            let commit = framed.subdata(in: (start + 4)..<(start + 4 + length))
            let welcome = framed.subdata(in: (start + 4 + length)..<framed.endIndex)
            guard let after = CommitPolicy.parseRosterFrame(try engine.dispatch(.membersAfterPending, Data())) else {
                throw MembershipError.inviteFrame
            }
            return (commit, welcome, after.map(\.id))
        }
        let members = roster.sorted().map { MemberWire(device: $0, actor: EnrollmentRequest.actor(of: $0)) }
        do {
            _ = try await transport.postEvent(room: room, EventPost(
                device: identity, clientId: clientId("add"), kind: .commit, epoch: sync.epoch, members: members, bytes: commit))
        } catch {
            // 409·네트워크·거부: 대기 commit 을 버려 epoch 를 그대로 둔다(relay-app 409 처리와 같음). 호출자가 동기화 후 다시 시도.
            try transaction { engine in if try engine.hasPending() { _ = try engine.dispatch(.clearPending, Data()) } }
            throw error
        }
        try await sync.syncAll()   // 내 echo → merge_pending (RoomSyncEngine)
        let stillPending = try stateStore.withExclusive(room: room, timeout: lockTimeout) { tx -> Bool in
            guard let bytes = try tx.load() else { return false }
            return try engineFactory.importState(identity: identity, bytes: bytes).hasPending()
        }
        if stillPending { throw MembershipError.ownCommitNotMerged }
        _ = try await transport.postEvent(room: room, EventPost(
            device: identity, clientId: clientId("welcome"), kind: .welcome, epoch: sync.epoch, targets: [target], bytes: welcome))
    }
}
