// 2기기 시나리오(#276 §2.4 수용 기준과 같은 순서) — 메모리 릴레이(IntegrationTests)와 실 릴레이(RelaySmokeTests)가 공유한다.
//
//   ① 두 기기: live() 조립(실 FFI 엔진 · FileStateStore · FileSQLiteStore), 로그인 → ready
//   ② 초대 → 참여: bob 키 패키지 게시 → alice 방 만들기·초대(commit + Welcome) → bob Welcome join
//   ③ 양방향: alice → bob, bob → alice 복호화
//   ④ 응답 유실 + 릴레이 중단/재시작: bob 송신 응답이 사라짐(.queued) → 릴레이 중단 중 refresh 실패 →
//      재시작 → 같은 바이트 재전송 = 200 duplicate(원래 seq) → alice 는 정확히 한 번 받는다
//   ⑤ commit 정책 위반: alice 의 상태 사본으로 만든 유효한 commit 을 다른 기기(mallory)가 게시 →
//      bob 이 stage → 정책 ①(committer_mismatch) → discard + ⛔ 정지, 재시작 뒤에도 유지
//   ⑥ 로비(#380 P5-3): alice(owner) 의 로비 키가 첫 바퀴에 올라가 있다 → bob 이 **새 방**을 만들고 alice 를 초대(방별 키 없음 →
//      로비 소비) → alice 는 탭 없이(「참여 요청」 없이) 방이 나타나고 join·복호화 → 쓰인 키만큼 로비가 다시 채워진다
// 각 단계는 실패 시 어느 단계인지 메시지에 남긴다(스모크 로그에서 시나리오별 통과/실패를 읽기 위해).
import CryptoKit
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class ScenarioDevice {
    let id: DeviceID
    let directory: URL
    let lossy: LossyTransport
    let sealKey: SymmetricKey
    /// 엔진 팩토리 감싸기(복호화 계수 등, §12-D 교차 프로세스 테스트). nil = 그대로.
    let wrapFactory: ((MlsEngineFactory) -> MlsEngineFactory)?
    private(set) var deps: AppModel.Dependencies
    private(set) var model: AppModel

    init(id: DeviceID, base: RelayTransport, root: URL, wrapFactory: ((MlsEngineFactory) -> MlsEngineFactory)? = nil) {
        self.id = id
        self.directory = root.appendingPathComponent(id, isDirectory: true)
        self.lossy = LossyTransport(base: base)
        self.sealKey = SymmetricKey(size: .bits256)
        self.wrapFactory = wrapFactory
        let made = Self.make(id: id, directory: directory, lossy: lossy, sealKey: sealKey, wrapFactory: wrapFactory)
        self.deps = made.deps
        self.model = made.model
    }

    private static func make(id: DeviceID, directory: URL, lossy: LossyTransport, sealKey: SymmetricKey,
                             wrapFactory: ((MlsEngineFactory) -> MlsEngineFactory)?) -> (deps: AppModel.Dependencies, model: AppModel) {
        var config = AppModel.Dependencies.LiveConfiguration()
        config.baseDirectory = directory
        config.sealer = ChaChaPolySealer(key: sealKey)   // Keychain 대신 정적 키(무서명 시뮬레이터) — 봉인 경로는 같다
        config.credentials = InMemoryCredentialStore()     // 기기마다 따로(시뮬레이터 Keychain 을 테스트끼리 공유하지 않게)
        config.identityProvider = { id }
        var deps = AppModel.Dependencies.live(config)
        deps.makeTransport = { _ in lossy }
        if let wrapFactory { deps.engineFactory = wrapFactory(deps.engineFactory) }
        return (deps: deps, model: AppModel(dependencies: deps))
    }

    /// 앱 재시작: 같은 디렉터리·같은 봉인 키로 저장소와 모델을 새로 연다. `configure` 로 의존성을 바꿀 수 있다(시나리오 ⑥ 자동 가입 actor).
    func relaunch(configure: ((inout AppModel.Dependencies) -> Void)? = nil) {
        let made = Self.make(id: id, directory: directory, lossy: lossy, sealKey: sealKey, wrapFactory: wrapFactory)
        var deps = made.deps
        configure?(&deps)
        self.deps = deps
        model = configure == nil ? made.model : AppModel(dependencies: deps)
    }

    /// 방 상태 파일의 서명키 지문(D2 검증용) — 상태를 열어 공개 정보만 읽는다.
    func roomFingerprint(_ room: RoomID) throws -> String? {
        try deps.stateStore.withExclusive(room: room, timeout: 2) { tx in
            try tx.load().map { try FfiEngineFactory().importState(identity: id, bytes: $0).fingerprint() }
        }
    }

    func roomStateBytes(_ room: RoomID) throws -> Data? {
        try deps.stateStore.withExclusive(room: room, timeout: 2) { try $0.load() }
    }

    func texts(_ room: RoomID) -> [String] {
        model.messages(room: room).map(\.record).filter { $0.kind == .text }.map(\.body)
    }
}

@MainActor
struct TwoDeviceScenario {
    let relay: RelayTransport
    let control: RelayControl
    let root: URL
    let room: RoomID

    /// 한 단계씩 진행하며 `log` 에 "PASS/FAIL 단계" 를 남긴다. 실패하면 그 단계에서 멈춘다.
    func run(log: (String) -> Void = { print("[scenario] \($0)") }) async throws {
        let alice = ScenarioDevice(id: "alice-iphone-a1a1a1", base: relay, root: root)
        let bob = ScenarioDevice(id: "bob-iphone-b2b2b2", base: relay, root: root)

        // ① 로그인 → ready
        for device in [alice, bob] {
            await device.model.bootstrap()
            device.model.login(.bearer("smoke"))
            await device.model.refresh()
            XCTAssertEqual(device.model.phase, .ready, "① \(device.id) ready (\(device.model.lastError ?? "-"))")
        }
        guard alice.model.phase == .ready, bob.model.phase == .ready else { log("FAIL ① login"); return }
        log("PASS ① login → ready (both)")

        // ② 초대 → 참여
        try await bob.model.requestJoin(room: room)
        try await alice.model.createRoom(room: room)
        try await alice.model.invite(room: room, target: bob.id)
        await bob.model.refresh()
        let aliceFP = try alice.roomFingerprint(room), bobFP = try bob.roomFingerprint(room)
        XCTAssertEqual(aliceFP, alice.model.fingerprint, "② D2: alice room state uses the identity signing key")
        XCTAssertEqual(bobFP, bob.model.fingerprint, "② D2: bob room state uses the identity signing key")
        XCTAssertEqual(bob.model.phase, .ready, "② bob ready after join (\(bob.model.lastError ?? "-"))")
        log("PASS ② invite → join (room \(room))")

        // ③ 양방향
        let first = await alice.model.send(room: room, text: "안녕 밥")
        guard case .sent(_, _, false)? = first else { XCTFail("③ alice send: \(String(describing: first)) \(alice.model.lastError ?? "-")"); log("FAIL ③"); return }
        await bob.model.refresh()
        XCTAssertEqual(bob.texts(room), ["안녕 밥"], "③ bob decrypts alice")
        let back = await bob.model.send(room: room, text: "안녕 앨리스")
        guard case .sent(_, _, false)? = back else { XCTFail("③ bob send: \(String(describing: back)) \(bob.model.lastError ?? "-")"); log("FAIL ③"); return }
        XCTAssertEqual(bob.texts(room), ["안녕 밥", "안녕 앨리스"], "③ bob's own message is recorded at its relay seq")
        await alice.model.refresh()
        XCTAssertEqual(alice.texts(room), ["안녕 밥", "안녕 앨리스"], "③ alice decrypts bob (and keeps her own)")
        guard alice.texts(room) == ["안녕 밥", "안녕 앨리스"] else { log("FAIL ③"); return }
        log("PASS ③ bidirectional E2EE")

        // ④ 응답 유실 → 릴레이 중단/재시작 → 정확 바이트 재전송 200 duplicate
        bob.lossy.dropNextPostResponse = true
        let lost = await bob.model.send(room: room, text: "재전송 확인")
        guard case .queued(let clientId)? = lost, let stored = bob.lossy.droppedResponse else {
            XCTFail("④ expected .queued after a dropped response, got \(String(describing: lost))"); log("FAIL ④ drop"); return
        }
        let pendingBytes = try bob.deps.outbox.pending(room: room).first { $0.clientId == clientId }?.bytes
        XCTAssertNotNil(pendingBytes, "④ entry stays pending with its exact bytes")
        try await control.stop()
        await bob.model.refresh()
        XCTAssertTrue(bob.model.reconnecting, "④ refresh while the relay is down shows 「연결 중입니다…」 (no raw error banner, #429)")
        XCTAssertEqual(try bob.deps.outbox.pending(room: room).first { $0.clientId == clientId }?.bytes, pendingBytes, "④ still pending, same bytes")
        try await control.start()
        await bob.model.refresh()
        let flushed = bob.model.lastFlush[room] ?? []
        XCTAssertTrue(flushed.contains(.sent(clientId: clientId, seq: stored.seq, duplicate: true)),
                      "④ exact-byte retransmit after restart = 200 duplicate at the original seq \(stored.seq); got \(flushed)")
        XCTAssertTrue(try bob.deps.outbox.pending(room: room).isEmpty, "④ outbox drained")
        await alice.model.refresh()
        XCTAssertEqual(alice.texts(room).filter { $0 == "재전송 확인" }.count, 1, "④ alice receives the retried message exactly once")
        log("PASS ④ dropped response → relay stop/start → exact-byte retransmit 200 duplicate (seq \(stored.seq))")

        // ⑤ commit 정책 위반 → ⛔ 정지
        guard let aliceState = try alice.roomStateBytes(room) else { XCTFail("⑤ alice room state"); return }
        let forger = try FfiEngineFactory().importState(identity: alice.id, bytes: aliceState)   // alice 의 유효한 leaf
        let carol = try FfiEngineFactory().create(identity: "carol-iphone-c3c3c3")
        let carolKP = try carol.dispatch(.keyPackage, Data())
        let framed = try forger.dispatch(.inviteWithCommit, carolKP)
        let commitLength = framed.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let forgedCommit = framed.subdata(in: (framed.startIndex + 4)..<(framed.startIndex + 4 + commitLength))
        let mallory = "mallory-iphone-d4d4d4"
        let current = try await relay.getEvents(room: room, device: mallory, after: 0, limit: 1, ack: nil).epoch
        let members = [alice.id, bob.id, "carol-iphone-c3c3c3", mallory].sorted().map { MemberWire(device: $0, actor: EnrollmentRequest.actor(of: $0)) }
        _ = try await relay.postEvent(room: room, EventPost(device: mallory, clientId: "\(mallory)-forged", kind: .commit,
                                                           epoch: current, members: members, bytes: forgedCommit))
        await bob.model.refresh()
        XCTAssertEqual(bob.model.phase, .halted(CommitRefusalReason.committerMismatch.rawValue), "⑤ bob halts on the forged committer")
        XCTAssertEqual(bob.model.rooms.first { $0.room == room }?.haltedReason, CommitRefusalReason.committerMismatch.rawValue)
        let afterHalt = await bob.model.send(room: room, text: "정지 중 송신")
        XCTAssertNil(afterHalt, "⑤ no send while halted")
        bob.relaunch()
        await bob.model.bootstrap()
        XCTAssertEqual(bob.model.rooms.first { $0.room == room }?.haltedReason, CommitRefusalReason.committerMismatch.rawValue, "⑤ halt survives relaunch")
        XCTAssertEqual(bob.model.fingerprint, bobFP, "⑤ relaunch keeps the same identity")
        XCTAssertTrue(bob.texts(room).contains("안녕 밥"), "⑤ decrypted history survives relaunch")
        log("PASS ⑤ forged committer → committer_mismatch ⛔ halt (persists across relaunch)")

        // ⑥ 로비: alice 의 로비 키는 ① 의 첫 바퀴에 올라갔다. alice 는 actor `alice`(자동 가입 대상이 아님) → 자동 가입 actor 에
        //    alice 를 넣은 모델로 다시 연다(가족 B 경로는 LobbyTests). 초대하는 쪽은 새 기기 dad(bob 은 ⑤에서 정지돼 보낼 수 없다).
        let lobbyRoom = "\(room)-lobby"
        alice.relaunch { deps in deps.autoJoinActors = ["owner", "alice"] }
        await alice.model.bootstrap()
        alice.model.login(.bearer("smoke"))
        await alice.model.refresh()
        XCTAssertEqual(alice.model.phase, .ready, "⑥ alice ready (\(alice.model.lastError ?? "-"))")
        XCTAssertEqual(alice.model.lobbyLive, 8, "⑥ the lobby is at the target after login (\(alice.model.lastError ?? "-"))")
        guard alice.model.lobbyLive == 8 else { log("FAIL ⑥ lobby replenish"); return }
        let dad = ScenarioDevice(id: "dad-iphone-d1d1d1", base: relay, root: root)
        await dad.model.bootstrap()
        dad.model.login(.bearer("smoke"))
        await dad.model.refresh()
        XCTAssertEqual(dad.model.phase, .ready, "⑥ dad ready (\(dad.model.lastError ?? "-"))")
        try await dad.model.createRoom(room: lobbyRoom)
        try await dad.model.invite(room: lobbyRoom, target: alice.id)   // alice 는 이 방에 '참여 요청' 한 적이 없다 → 로비 소비
        await alice.model.refresh()
        XCTAssertTrue(alice.model.rooms.contains { $0.room == lobbyRoom }, "⑥ the room appears on alice without any tap: \(alice.model.rooms.map(\.room)) (\(alice.model.lastError ?? "-"))")
        XCTAssertEqual(alice.model.notice, Strings.lobbyJoined(lobbyRoom), "⑥ auto-join notice (\(alice.model.lastError ?? "-"))")
        XCTAssertEqual(try alice.roomFingerprint(lobbyRoom), alice.model.fingerprint, "⑥ D2 still holds: the adopted room state carries the identity signing key")
        let hello = await dad.model.send(room: lobbyRoom, text: "로비로 들어온 앨리스")
        guard case .sent? = hello else { XCTFail("⑥ dad send: \(String(describing: hello)) \(dad.model.lastError ?? "-")"); log("FAIL ⑥ send"); return }
        await alice.model.refresh()
        XCTAssertEqual(alice.texts(lobbyRoom), ["로비로 들어온 앨리스"], "⑥ alice decrypts in the lobby-joined room")
        let reply = await alice.model.send(room: lobbyRoom, text: "탭 없이 들어왔어")
        guard case .sent? = reply else { XCTFail("⑥ alice send: \(String(describing: reply)) \(alice.model.lastError ?? "-")"); log("FAIL ⑥ reply"); return }
        await dad.model.refresh()
        XCTAssertEqual(dad.texts(lobbyRoom), ["로비로 들어온 앨리스", "탭 없이 들어왔어"], "⑥ dad decrypts alice's reply")
        XCTAssertEqual(alice.model.lobbyLive, 8, "⑥ the consumed lobby key was replenished after the join (\(alice.model.lastError ?? "-"))")
        // alice 의 답장은 서버 seq 를 받은 순간 자기 화면에도 기록된다(recordOwn) → 양쪽 모두 2건.
        guard alice.texts(lobbyRoom) == ["로비로 들어온 앨리스", "탭 없이 들어왔어"], dad.texts(lobbyRoom).count == 2, alice.model.lobbyLive == 8 else {
            log("FAIL ⑥ alice=\(alice.texts(lobbyRoom)) dad=\(dad.texts(lobbyRoom)) lobbyLive=\(String(describing: alice.model.lobbyLive)) err=\(alice.model.lastError ?? "-")"); return
        }
        log("PASS ⑥ lobby key → invite without a join request → tapless join + E2EE both ways + replenish (room \(lobbyRoom))")
    }
}
