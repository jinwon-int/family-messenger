// 2기기 시나리오(#276 §2.4 수용 기준과 같은 순서) — 메모리 릴레이(IntegrationTests)와 실 릴레이(RelaySmokeTests)가 공유한다.
//
//   ① 두 기기: live() 조립(실 FFI 엔진 · FileStateStore · FileSQLiteStore), 로그인 → ready
//   ② 초대 → 참여: bob 키 패키지 게시 → alice 방 만들기·초대(commit + Welcome) → bob Welcome join
//   ③ 양방향: alice → bob, bob → alice 복호화
//   ④ 응답 유실 + 릴레이 중단/재시작: bob 송신 응답이 사라짐(.queued) → 릴레이 중단 중 refresh 실패 →
//      재시작 → 같은 바이트 재전송 = 200 duplicate(원래 seq) → alice 는 정확히 한 번 받는다
//   ⑤ commit 정책 위반: alice 의 상태 사본으로 만든 유효한 commit 을 다른 기기(mallory)가 게시 →
//      bob 이 stage → 정책 ①(committer_mismatch) → discard + ⛔ 정지, 재시작 뒤에도 유지
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
    private(set) var deps: AppModel.Dependencies
    private(set) var model: AppModel

    init(id: DeviceID, base: RelayTransport, root: URL) {
        self.id = id
        self.directory = root.appendingPathComponent(id, isDirectory: true)
        self.lossy = LossyTransport(base: base)
        self.sealKey = SymmetricKey(size: .bits256)
        let made = Self.make(id: id, directory: directory, lossy: lossy, sealKey: sealKey)
        self.deps = made.deps
        self.model = made.model
    }

    private static func make(id: DeviceID, directory: URL, lossy: LossyTransport, sealKey: SymmetricKey) -> (deps: AppModel.Dependencies, model: AppModel) {
        var config = AppModel.Dependencies.LiveConfiguration()
        config.baseDirectory = directory
        config.sealer = ChaChaPolySealer(key: sealKey)   // Keychain 대신 정적 키(무서명 시뮬레이터) — 봉인 경로는 같다
        config.identityProvider = { id }
        var deps = AppModel.Dependencies.live(config)
        deps.makeTransport = { _ in lossy }
        return (deps: deps, model: AppModel(dependencies: deps))
    }

    /// 앱 재시작: 같은 디렉터리·같은 봉인 키로 저장소와 모델을 새로 연다.
    func relaunch() {
        let made = Self.make(id: id, directory: directory, lossy: lossy, sealKey: sealKey)
        deps = made.deps
        model = made.model
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
        model.messages(room: room).filter { $0.kind == .text }.map(\.body)
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
        XCTAssertNotNil(bob.model.lastError, "④ refresh while the relay is down reports a network error")
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
    }
}
