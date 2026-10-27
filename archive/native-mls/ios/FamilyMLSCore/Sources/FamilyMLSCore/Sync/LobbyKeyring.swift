// 로비 key package 키링 (#380 P5-3) — 사람 기기 탭 없이 초대받기 위한 **방 무관** key package 묶음.
//
// 배경: 방별 key package(`RoomMembership.publishKeyPackage`)는 그 방 상태에만 비밀(init 키)이 있어, 기기가 먼저 그 방에
// 「참여 요청」을 해야 초대받을 수 있다. 로비(server/lobby.go, P5-1)는 기기가 한 번 올려 두면 steward 봇이 어느 방에서든
// 소비(`consumed_room` 기록)해 Welcome 을 보낸다. 그 Welcome 을 열려면 **소비된 key package 의 비밀**이 그 방의 엔진 상태에
// 있어야 하므로, 비밀은 `_lobby` 슬롯 하나에 모아 두고 새 방 상태는 이 슬롯 바이트를 복사해 시작한다(`adoptRoom`).
// 파사드 규칙(openmls-browser lib.rs): 기기당 미사용 key package ≤ 8(`key package limit`), `join` 은 남은 것을 모두 지운다
// — 방 상태 사본에서 지워지지 `_lobby` 슬롯에는 남는다.
//
// 슬롯 바이트(JSON `LobbySlot`): `state` = 파사드 export_state(서명키 = `_identity` 시드 + 로비 key package 비밀),
// `published` = 릴레이가 받은 key package 바이트(게시 순). **릴레이는 가장 오래된 것부터 소비·만료**(lobby.go `ORDER BY rowid`,
// 균일 TTL)하므로 서버의 `live` 수만 알면 장부 앞쪽 `published.count - live` 개가 소비·만료된 것이다 — 그만큼 로컬 비밀을
// `delete_key_package` 로 지워 로컬 상한(8)을 비우고, 부족분을 새로 만들어 게시한다(`replenish`). 단, 아직 참여하지 않은 Welcome 이 쓴
// key package(릴레이 `key_package_ref`)는 `protect` 로 남긴다 — 지우면 그 Welcome 을 영영 열 수 없다(#518).
//
// 네트워크는 트랜잭션 밖(CONTRACTS §3.4). 게시에 실패한 새 key package 는 비밀을 바로 지운다 — 서버에 없는 키는 로컬 상한만 차지한다.
import Foundation

/// `_lobby` 슬롯의 저장 형식.
public struct LobbySlot: Codable, Equatable {
    public var state: Data
    public var published: [Data]
    public init(state: Data, published: [Data] = []) { self.state = state; self.published = published }
}

/// `replenish` 한 번의 결과(화면·테스트).
public struct LobbyReport: Equatable {
    /// 보충 뒤 서버의 미소비 수.
    public var live: Int
    public var max: Int
    public var minted: Int
    /// 소비·만료된 것으로 판단해 로컬 비밀을 지운 수.
    public var pruned: Int
    /// 소비·만료된 것으로 판단했지만 지우지 않고 장부 앞쪽에 남긴 수(`protect`·`prune: false`, #518).
    public var kept: Int
    public init(live: Int, max: Int, minted: Int, pruned: Int, kept: Int = 0) {
        self.live = live; self.max = max; self.minted = minted; self.pruned = pruned; self.kept = kept
    }
}

public final class LobbyKeyring {
    /// 상태 저장소의 슬롯 이름. 방 목록(`MessageStore.rooms`)에는 나타나지 않는다(`_identity` 와 같은 자리).
    public static let slot: RoomID = "_lobby"

    public let identity: DeviceID
    private let engineFactory: MlsEngineFactory
    private let stateStore: MlsStateStore
    private let transport: RelayTransport
    private let lockTimeout: TimeInterval
    /// key package `ref` = sha256 hex(봇·relay-app 규칙). Core 에는 CryptoKit 이 없어 호출자가 준다.
    private let makeRef: (Data) -> String

    /// `engineFactory.create` 는 이 기기의 **identity 시드**를 돌려줘야 한다(앱의 `SeededEngineFactory`) — 서명키가 방들과 같아야
    /// 릴레이 정책 체인(기기당 키 1개)과 어긋나지 않는다.
    public init(identity: DeviceID, engineFactory: MlsEngineFactory, stateStore: MlsStateStore, transport: RelayTransport,
                lockTimeout: TimeInterval = 5, makeRef: @escaping (Data) -> String) {
        self.identity = identity; self.engineFactory = engineFactory; self.stateStore = stateStore
        self.transport = transport; self.lockTimeout = lockTimeout; self.makeRef = makeRef
    }

    // MARK: - 보충

    /// 서버의 미소비 수가 `min(target, 서버 max)` 보다 적으면 그만큼 만들어 게시한다. 먼저 장부 앞쪽(소비·만료분)의 로컬 비밀을 지운다.
    /// 릴레이에 로비가 없으면(404) `RelayError.refused(status: 404)` 를 그대로 던진다 — 호출자가 "로비 없음" 으로 건너뛴다.
    ///
    /// #518: 소비된 key package 하나는 **아직 참여하지 않은 Welcome** 이 쓴 것일 수 있다 — 그 비밀을 지우면 그 Welcome 은 영영 열 수 없다.
    /// `protect` 에 든 ref(`makeRef` 규칙 = 릴레이 `key_package_ref`)는 소비분이어도 지우지 않고 장부 **앞쪽에 그대로** 둔다(FIFO 가 유지되어
    /// 보호가 풀린 뒤의 보충이 정확히 그것부터 지운다). `prune: false` 는 소비분 전부를 그렇게 둔다(ref 를 모르는 옛 릴레이용). 발행은 계속하되
    /// 남긴 비밀도 로컬 상한(8)을 차지하므로 그만큼 덜 만들어질 수 있다.
    @discardableResult
    public func replenish(target: Int, protect: Set<String> = [], prune: Bool = true) async throws -> LobbyReport {
        let status = try await transport.lobbyStatus(device: identity)
        let goal = max(0, min(target, status.max))
        let (fresh, pruned, kept): ([Data], Int, Int) = try transaction { slot, engine in
            let consumed = min(max(0, slot.published.count - status.live), slot.published.count)
            var pruned = 0
            var kept: [Data] = []
            for bytes in slot.published.prefix(consumed) {
                if !prune || protect.contains(makeRef(bytes)) { kept.append(bytes); continue }
                // 이미 없는(방 사본에서만 지워졌거나 모르는) 것은 거부되지만 장부에서는 뺀다.
                if (try? engine.dispatch(.deleteKeyPackage, bytes)) != nil { pruned += 1 }
            }
            slot.published.replaceSubrange(0..<consumed, with: kept)
            var fresh: [Data] = []
            var want = goal - status.live
            while want > 0 {
                do { fresh.append(try engine.dispatch(.keyPackage, Data())) } catch EngineError.rejected { break }   // 로컬 상한
                want -= 1
            }
            return (fresh, pruned, kept.count)
        }
        guard !fresh.isEmpty else { return LobbyReport(live: status.live, max: status.max, minted: 0, pruned: pruned, kept: kept) }
        let response: KeyPackagesResponse
        do {
            response = try await transport.postLobbyKeyPackages(KeyPackagePost(
                device: identity, packages: fresh.map { KeyPackageInput(ref: makeRef($0), bytes: $0) }))
        } catch {
            // 서버가 받지 않은 키의 비밀은 버린다(상한만 차지한다). 다음 보충이 다시 만든다.
            _ = try? transaction { _, engine in for bytes in fresh { _ = try? engine.dispatch(.deleteKeyPackage, bytes) } }
            throw error
        }
        try transaction { slot, _ in slot.published.append(contentsOf: fresh) }
        return LobbyReport(live: response.live ?? (status.live + fresh.count), max: status.max, minted: fresh.count, pruned: pruned, kept: kept)
    }

    /// 장부에 있는(릴레이가 받은) key package 수 — 화면용. 슬롯이 없으면 0.
    public func publishedCount() throws -> Int {
        try stateStore.withExclusive(room: Self.slot, timeout: lockTimeout) { tx in try tx.load().map(Self.decode)?.published.count ?? 0 }
    }

    // MARK: - 모르는 방 받아들이기

    /// 이 기기가 `room` 의 그룹 멤버인가(상태를 읽기만 한다). 상태가 없으면 false.
    public func isMember(room: RoomID) throws -> Bool {
        try stateStore.withExclusive(room: room, timeout: lockTimeout) { tx in
            guard let bytes = try tx.load() else { return false }
            return Self.isMember(try engineFactory.importState(identity: identity, bytes: bytes), identity)
        }
    }

    /// `room` 의 엔진 상태를 `_lobby` 슬롯의 상태로 **바꾼다**(그 방의 Welcome 이 로비 key package 로 만들어졌을 때 join 할 수 있게).
    /// 이미 그룹 멤버인 방(참여 끝)이나 로비 슬롯이 없을 때는 아무것도 하지 않고 false. 그룹이 없는 기존 상태(identity 시드로
    /// 시작했거나 방별 참여 요청만 한 상태)는 덮어쓴다 — 그 상태로는 이 Welcome 을 열 수 없었다.
    /// 호출자는 그 방의 캐시된 동기화 객체를 버리고 커서를 Welcome 앞으로 되돌린 뒤 동기화한다(AppModel).
    @discardableResult
    public func adoptRoom(_ room: RoomID) throws -> Bool {
        guard room != Self.slot else { return false }
        let seed = try stateStore.withExclusive(room: Self.slot, timeout: lockTimeout) { tx in try tx.load().map(Self.decode)?.state }
        guard let seed else { return false }
        return try stateStore.withExclusive(room: room, timeout: lockTimeout) { tx in
            if let bytes = try tx.load(), Self.isMember(try engineFactory.importState(identity: identity, bytes: bytes), identity) {
                return false
            }
            try tx.save(seed)
            return true
        }
    }

    // MARK: - 내부

    private func transaction<T>(_ body: (inout LobbySlot, MlsEngine) throws -> T) throws -> T {
        try stateStore.withExclusive(room: Self.slot, timeout: lockTimeout) { tx in
            var slot: LobbySlot
            let engine: MlsEngine
            if let bytes = try tx.load() {
                slot = try Self.decode(bytes)
                engine = try engineFactory.importState(identity: identity, bytes: slot.state)
            } else {
                engine = try engineFactory.create(identity: identity)
                slot = LobbySlot(state: try engine.exportState())
            }
            let result = try body(&slot, engine)
            slot.state = try engine.exportState()
            try tx.save(try Self.encode(slot))
            return result
        }
    }

    static func isMember(_ engine: MlsEngine, _ identity: DeviceID) -> Bool {
        guard let frame = try? engine.dispatch(.members, Data()) else { return false }   // 그룹 없음 = .rejected
        return CommitPolicy.parseRosterFrame(frame)?.contains { $0.id == identity } ?? false
    }

    static func encode(_ slot: LobbySlot) throws -> Data {
        do { return try JSONEncoder().encode(slot) } catch { throw StateStoreError.io("lobby slot encode: \(error)") }
    }

    static func decode(_ bytes: Data) throws -> LobbySlot {
        do { return try JSONDecoder().decode(LobbySlot.self, from: bytes) } catch { throw StateStoreError.io("lobby slot decode: \(error)") }
    }
}
