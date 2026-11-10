// 기기 셀프서비스 순수 판정(#574 PR 3) — 웹 `web/hande/tests/self-service.test.mjs` 와 같은 사례를 Swift 로(Linux `swift test`).
import XCTest
@testable import FamilyMLSCore

final class SelfServiceTests: XCTestCase {
    private let key = String(repeating: "ab", count: 32)
    private let fp = String(repeating: "cd", count: 32)

    private func dev(_ id: DeviceID, status: String = "active", roles: [String] = [], actor: String? = nil) -> MeDevice {
        MeDevice(deviceId: id, actor: actor ?? String(id.split(separator: "-").first ?? ""), fingerprint: fp, status: status, acceptance: "operator", roles: roles)
    }
    private func me(_ devices: MeDevice...) -> MeResponse { MeResponse(subject: "sub-1", policyRevision: 7, devices: devices) }

    func testCanApproveIsActiveAndRegistrarOrActorWithoutRegistrar() {
        let pre574 = me(dev("mom-web-a"), dev("mom-iphone-b"))
        XCTAssertTrue(SelfService.canApprove(pre574, device: "mom-web-a"), "registrar 가 없으면 활성 기기 누구나")
        XCTAssertFalse(SelfService.canApprove(me(dev("mom-web-a", status: "revoked"), dev("mom-iphone-b")), device: "mom-web-a"), "폐기 기기는 못 한다")
        let withReg = me(dev("mom-web-a"), dev("mom-iphone-b", roles: ["registrar"]))
        XCTAssertFalse(SelfService.canApprove(withReg, device: "mom-web-a"), "registrar 가 생기면 그 기기만")
        XCTAssertTrue(SelfService.canApprove(withReg, device: "mom-iphone-b"))
        XCTAssertTrue(SelfService.canApprove(me(dev("mom-web-a"), dev("mom-iphone-b", status: "revoked", roles: ["registrar"])), device: "mom-web-a"),
                      "폐기된 registrar 는 세지 않는다")
        XCTAssertFalse(SelfService.canApprove(withReg, device: "dad-web-z"), "체인에 없는 기기")
        XCTAssertFalse(SelfService.canApprove(nil, device: "mom-web-a"), "/v2/me 없음(접근 인증 꺼짐)")
        XCTAssertFalse(SelfService.canApprove(MeResponse(subject: "sub-1"), device: "mom-web-a"), "옛 릴레이(devices 없음)")
        XCTAssertTrue(SelfService.actorHasRegistrar(withReg, actor: "mom"))
        XCTAssertFalse(SelfService.actorHasRegistrar(withReg, actor: "dad"))
        XCTAssertEqual(SelfService.record(of: withReg, device: "mom-iphone-b")?.roles, ["registrar"])
        XCTAssertNil(SelfService.record(of: withReg, device: "nope"))
    }

    func testIsSiblingOnlyForAnotherActiveDeviceOfMyActor() {
        let info = me(dev("mom-web-a"), dev("mom-iphone-b"), dev("mom-old-c", status: "revoked"), dev("dad-web-d"))
        XCTAssertTrue(SelfService.isSibling(from: "mom-iphone-b", me: info, actor: "mom", device: "mom-web-a"))
        XCTAssertFalse(SelfService.isSibling(from: "mom-web-a", me: info, actor: "mom", device: "mom-web-a"), "나 자신")
        XCTAssertFalse(SelfService.isSibling(from: "mom-old-c", me: info, actor: "mom", device: "mom-web-a"), "폐기된 기기")
        XCTAssertFalse(SelfService.isSibling(from: "dad-web-d", me: info, actor: "mom", device: "mom-web-a"), "다른 사람")
        XCTAssertFalse(SelfService.isSibling(from: "mom-ghost", me: info, actor: "mom", device: "mom-web-a"), "체인에 없음")
        XCTAssertFalse(SelfService.isSibling(from: nil, me: info, actor: "mom", device: "mom-web-a"), "옛 릴레이는 from 이 없다")
        XCTAssertFalse(SelfService.isSibling(from: "mom-iphone-b", me: nil, actor: "mom", device: "mom-web-a"))
        XCTAssertFalse(SelfService.isSibling(from: "mom-iphone-b", me: info, actor: nil, device: "mom-web-a"))
    }

    private func candidate(_ id: DeviceID, actor: String, key: String? = nil, fingerprint: String? = nil) -> DeviceCandidate {
        DeviceCandidate(deviceId: id, actor: actor, subject: "sub-1", signingKey: key ?? self.key, fingerprint: fingerprint ?? fp, createdAt: 1, expiresAt: 601)
    }

    func testCandidatesForMyActorAndWellFormedOnly() {
        let list = DeviceCandidates(policyRevision: 7, candidates: [
            candidate("mom-pc-1", actor: "mom"), candidate("dad-pc-2", actor: "dad"),
            candidate("mom-pc-3", actor: "mom", key: "zz"), candidate("mom-pc-4", actor: "mom", fingerprint: String(repeating: "C", count: 64)),
        ])
        XCTAssertEqual(SelfService.candidates(in: list, actor: "mom").map(\.deviceId), ["mom-pc-1"], "대문자 hex·짧은 키는 모양이 온전하지 않다")
        XCTAssertEqual(SelfService.candidates(in: nil, actor: "mom"), [])
    }

    func testApprovalArgsAndEvidenceShapes() throws {
        let c = candidate("mom-pc-1", actor: "mom")
        let args = try SelfService.approvalArgs(c, baseRevision: 7)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(args)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["action", "device_id", "actor", "subject", "signing_key", "acceptance", "base_revision"], "파사드가 받는 정확한 키 집합")
        XCTAssertEqual(json["action"] as? String, "approve-device")
        XCTAssertEqual(json["acceptance"] as? String, "trusted-device-fingerprint")
        XCTAssertEqual(json["base_revision"] as? Int, 7)
        XCTAssertEqual(json["signing_key"] as? String, key)
        XCTAssertThrowsError(try SelfService.approvalArgs(c, baseRevision: 0)) { XCTAssertEqual($0 as? SelfService.Failure, .baseRevision) }
        XCTAssertThrowsError(try SelfService.approvalArgs(c, baseRevision: nil)) { XCTAssertEqual($0 as? SelfService.Failure, .baseRevision) }
        let signature = String(repeating: "ff", count: 64)
        let evidence = SelfService.approvalEvidence(args, signature: signature, fingerprint: fp, approvedBy: "mom-web-a")
        XCTAssertEqual(evidence, DeviceApprovalEvidence(deviceId: "mom-pc-1", actor: "mom", subject: "sub-1", signingKey: key, baseRevision: 7,
                                                        signature: signature, fingerprint: fp, approvedBy: "mom-web-a"))
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        XCTAssertEqual(Set(wire.keys), ["device_id", "actor", "subject", "signing_key", "base_revision", "signature", "fingerprint", "approved_by"],
                       "AddDeviceEvidence 는 strict JSON — action·acceptance 없음")
    }

    func testNextRolesRolesArgsAndEvidence() throws {
        XCTAssertEqual(SelfService.nextRoles([], grant: true), ["registrar"])
        XCTAssertEqual(SelfService.nextRoles(["registrar"], grant: true), ["registrar"])
        XCTAssertEqual(SelfService.nextRoles(["zeta", "registrar"], grant: false), ["zeta"])
        XCTAssertEqual(SelfService.nextRoles(["registrar", "registrar"], grant: true), ["registrar"], "중복 없음")
        let args = try SelfService.rolesArgs(dev("mom-iphone-b"), roles: ["registrar"], baseRevision: 7)
        XCTAssertEqual(args, SelfService.RolesArgs(deviceId: "mom-iphone-b", actor: "mom", roles: ["registrar"], baseRevision: 7))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(args)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["device_id", "actor", "roles", "base_revision"])
        XCTAssertEqual(json["roles"] as? [String], ["registrar"])
        XCTAssertThrowsError(try SelfService.rolesArgs(dev("mom-iphone-b"), roles: [], baseRevision: 0))
        let none = try SelfService.rolesArgs(dev("mom-iphone-b"), roles: [], baseRevision: 8)
        let emptyRoles = String(decoding: try JSONEncoder().encode(none), as: UTF8.self)
        XCTAssertTrue(emptyRoles.contains("\"roles\":[]"), "빈 배열 = 역할 없음(null 금지): \(emptyRoles)")
        let signature = String(repeating: "ee", count: 64)
        XCTAssertEqual(SelfService.rolesEvidence(args, signature: signature, approvedBy: "mom-web-a"),
                       DeviceRolesEvidence(deviceId: "mom-iphone-b", actor: "mom", roles: ["registrar"], baseRevision: 7, signature: signature, approvedBy: "mom-web-a"))
    }

    func testRolesActions() {
        func by(_ view: SelfService.RolesView) -> [DeviceID: SelfService.DeviceRow] { Dictionary(uniqueKeysWithValues: view.devices.map { ($0.deviceId, $0) }) }
        // registrar 가 없는 actor: 활성 기기 누구나 서명·부여 가능(부트스트랩), 해제할 것은 없음.
        let boot = SelfService.rolesActions(me(dev("mom-web-a"), dev("mom-iphone-b"), dev("mom-old-c", status: "revoked"), dev("dad-web-d")), device: "mom-web-a")
        XCTAssertTrue(boot.canSign); XCTAssertEqual(boot.actor, "mom")
        var v = by(boot)
        XCTAssertEqual([v["mom-web-a"]?.grant, v["mom-web-a"]?.release, v["mom-web-a"]?.isSelf], [true, false, true])
        XCTAssertEqual([v["mom-iphone-b"]?.grant, v["mom-iphone-b"]?.release], [true, false])
        XCTAssertEqual([v["mom-old-c"]?.grant, v["mom-old-c"]?.release], [false, false], "폐기 기기는 보이되 손댈 수 없다")
        XCTAssertEqual(v["mom-old-c"]?.status, "revoked")
        XCTAssertEqual([v["dad-web-d"]?.grant, v["dad-web-d"]?.release], [false, false], "다른 actor")
        // registrar 하나뿐: 그 기기는 해제 불가(lastRegistrar), 다른 기기에 부여는 가능.
        let one = SelfService.rolesActions(me(dev("mom-web-a", roles: ["registrar"]), dev("mom-iphone-b")), device: "mom-web-a")
        v = by(one)
        XCTAssertEqual([v["mom-web-a"]?.grant, v["mom-web-a"]?.release, v["mom-web-a"]?.lastRegistrar, v["mom-web-a"]?.registrar], [false, false, true, true])
        XCTAssertEqual([v["mom-iphone-b"]?.grant, v["mom-iphone-b"]?.release], [true, false])
        // registrar 둘: 둘 다 해제 가능(자기 자신 포함 — 다른 하나가 남는다).
        let two = SelfService.rolesActions(me(dev("mom-web-a", roles: ["registrar"]), dev("mom-iphone-b", roles: ["registrar"])), device: "mom-web-a")
        v = by(two)
        XCTAssertEqual([v["mom-web-a"]?.release, v["mom-iphone-b"]?.release, v["mom-web-a"]?.lastRegistrar], [true, true, false])
        // registrar 가 있는데 내가 아니면: 서명 불가, 모든 버튼 꺼짐.
        let notMe = SelfService.rolesActions(me(dev("mom-web-a"), dev("mom-iphone-b", roles: ["registrar"])), device: "mom-web-a")
        XCTAssertFalse(notMe.canSign)
        XCTAssertTrue(notMe.devices.allSatisfy { !$0.grant && !$0.release })
        XCTAssertEqual(SelfService.rolesActions(nil, device: "mom-web-a"), .empty, "체인 모름")
    }

    func testSiblingInviteRooms() {
        let rooms = [
            SelfService.RoomView(roomId: "family", joined: true, halted: false, pending: false, roster: ["mom-web-a", "dad-web-d"]),
            SelfService.RoomView(roomId: "already", joined: true, halted: false, pending: false, roster: ["mom-web-a", "mom-pc-1"]),
            SelfService.RoomView(roomId: "halted", joined: true, halted: true, pending: false, roster: ["mom-web-a"]),
            SelfService.RoomView(roomId: "pending", joined: true, halted: false, pending: true, roster: ["mom-web-a"]),
            SelfService.RoomView(roomId: "notjoined", joined: false, halted: false, pending: false, roster: []),
            SelfService.RoomView(roomId: "noroster", joined: true, halted: false, pending: false, roster: nil),
        ]
        XCTAssertEqual(SelfService.siblingInviteRooms(rooms, target: "mom-pc-1"), ["family", "noroster"])
        XCTAssertEqual(SelfService.siblingInviteRooms([], target: "mom-pc-1"), [])
    }

    func testEnrollModeFromPostResult() {
        XCTAssertEqual(SelfService.enrollMode(afterPost: nil), .sibling)
        XCTAssertEqual(SelfService.enrollMode(afterPost: RelayError.refused(code: "device_exists", status: 409)), .idTaken)
        XCTAssertEqual(SelfService.enrollMode(afterPost: RelayError.refused(code: "other", status: 409)), .operatorFlow)
        XCTAssertEqual(SelfService.enrollMode(afterPost: RelayError.refused(code: "first_device_out_of_band", status: 403)), .operatorFlow)
        XCTAssertEqual(SelfService.enrollMode(afterPost: RelayError.refused(code: "subject_mismatch", status: 403)), .operatorFlow)
        XCTAssertEqual(SelfService.enrollMode(afterPost: RelayError.refused(code: "http_404", status: 404)), .operatorFlow)
        XCTAssertEqual(SelfService.enrollMode(afterPost: RelayError.network("down")), .operatorFlow)
    }

    func testSiblingInviteQueueMergesAndSplitsByTTL() {
        var q = SiblingInviteQueue().enqueued(target: "mom-pc-1", rooms: ["family", "family"], now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(q.entries, [SiblingInviteQueue.Entry(target: "mom-pc-1", rooms: ["family"], since: 1)])
        q = q.enqueued(target: "mom-pc-1", rooms: ["family", "acc"], now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(q.entries, [SiblingInviteQueue.Entry(target: "mom-pc-1", rooms: ["family", "acc"], since: 1)], "시각은 처음 것, 방은 합집합")
        q = q.enqueued(target: "mom-pc-2", rooms: [], now: Date(timeIntervalSince1970: 6))
        XCTAssertEqual(q.entries.count, 1, "방이 없으면 넣지 않는다")
        q = q.enqueued(target: "mom-pc-2", rooms: ["family"], now: Date(timeIntervalSince1970: 6))
        let (live, expired) = q.split(now: Date(timeIntervalSince1970: 1 + SelfService.siblingInviteTTL + 1))
        XCTAssertEqual(live.map(\.target), ["mom-pc-2"])
        XCTAssertEqual(expired.map(\.target), ["mom-pc-1"])
        XCTAssertEqual(q.split(now: Date(timeIntervalSince1970: 100)).expired, [])
    }

    // MARK: - #616: 형제 초대가 로비 키 상한(8)에 막혀 9번째 방부터 빠지던 문제

    func testSiblingQueueTTLCountsFromLastProgress() {
        let q = SiblingInviteQueue([
            SiblingInviteQueue.Entry(target: "a", rooms: ["x"], since: 0, progress: 10 * 3600),
            SiblingInviteQueue.Entry(target: "b", rooms: ["x"], since: 0),
        ])
        let (live, expired) = q.split(now: Date(timeIntervalSince1970: SelfService.siblingInviteTTL + 1))
        XCTAssertEqual(live.map(\.target), ["a"])
        XCTAssertEqual(expired.map(\.target), ["b"])
        XCTAssertGreaterThanOrEqual(SelfService.siblingInviteTTL, 24 * 3600, "15시간 백그라운드였던 탭(10-30)도 기다린다")
        XCTAssertEqual(SiblingInviteQueue.budget(live: nil), Int.max, "모르면 예전처럼 제한 없음")
        XCTAssertEqual(SiblingInviteQueue.budget(live: 3), 3)
        XCTAssertEqual(SiblingInviteQueue.budget(live: -1), 0)
    }

    func testOldStoredEntriesDecodeWithoutTheNewFields() throws {
        let entry = try JSONDecoder().decode(SiblingInviteQueue.Entry.self, from: Data(#"{"target":"t","rooms":["r"],"since":5}"#.utf8))
        XCTAssertEqual(entry, SiblingInviteQueue.Entry(target: "t", rooms: ["r"], since: 5))
        XCTAssertNil(entry.progress); XCTAssertNil(entry.recheckAt)
    }

    private enum InviteFailure: Error { case noKey, refused }

    /// 형제 기기(새 웹 기기) 흉내: 로비 키 상한 8, 초대가 하나씩 쓰고, `replenish()` 가 상한까지 채운다.
    @MainActor
    private final class Sibling {
        var live = 0, statusCalls = 0, inviteCalls = 0
        var members: Set<RoomID> = []
        func replenish() { live = 8 }
        func lobbyLive() async -> Int? { statusCalls += 1; return live }
        func invite(_ room: RoomID) async throws {
            inviteCalls += 1
            guard live > 0 else { throw InviteFailure.noKey }
            live -= 1; members.insert(room)
        }
        func view(_ room: RoomID) -> SelfService.RoomView? {
            SelfService.RoomView(roomId: room, joined: true, halted: false, pending: false, roster: members.contains(room) ? ["t-web"] : ["me"])
        }
    }

    @MainActor
    private func turn(_ e: SiblingInviteQueue.Entry, _ now: TimeInterval, _ sib: Sibling) async throws -> SiblingInviteQueue.Turn {
        try await SiblingInviteQueue.turn(e, now: Date(timeIntervalSince1970: now), lobbyLive: { await sib.lobbyLive() },
                                          roomView: { sib.view($0) }, invite: { try await sib.invite($0) },
                                          isRetryable: { ($0 as? InviteFailure) == .noKey }, isNoKey: { ($0 as? InviteFailure) == .noKey })
    }

    /// 10-30 실측: 방 17개 · 로비 키 8개. 잔량만큼만 쓰고, 키가 없으면 기다렸다가 보충되면 마저 들인다 — 실패한 초대 시도 0.
    @MainActor
    func testSeventeenRoomsWithEightLobbyKeysAllJoinWithoutFailedInvites() async throws {
        let sib = Sibling()
        var entry = SiblingInviteQueue.Entry(target: "t-web", rooms: (1...17).map { "room\($0)" }, since: 0)
        var now: TimeInterval = 0
        var r = try await turn(entry, now, sib)
        XCTAssertEqual(sib.inviteCalls, 0, "잔량 0 이면 404 를 쌓지 않는다")
        XCTAssertEqual(r.entry?.recheckAt, now + SelfService.siblingLobbyRecheck)
        entry = try XCTUnwrap(r.entry)
        let calls = sib.statusCalls
        _ = try await turn(entry, now + 1, sib)
        XCTAssertEqual(sib.statusCalls, calls, "다시 물을 시각 전에는 잔량도 묻지 않는다")
        sib.replenish(); now += SelfService.siblingLobbyRecheck
        r = try await turn(entry, now, sib)
        XCTAssertEqual(r.invited.count, 8)
        XCTAssertEqual(sib.inviteCalls, 8, "9번째 방에서 404 를 내지 않는다")
        XCTAssertEqual(r.entry?.rooms.count, 9)
        XCTAssertEqual(r.entry?.progress, now)
        entry = try XCTUnwrap(r.entry)
        now += 15 * 3600   // 새 기기 탭이 15시간 백그라운드
        XCTAssertTrue(SiblingInviteQueue([entry]).split(now: Date(timeIntervalSince1970: now)).expired.isEmpty)
        r = try await turn(entry, now, sib); entry = try XCTUnwrap(r.entry)
        XCTAssertTrue(r.invited.isEmpty)
        sib.replenish(); now += SelfService.siblingLobbyRecheck
        r = try await turn(entry, now, sib); entry = try XCTUnwrap(r.entry)
        XCTAssertEqual(r.invited.count, 8)
        sib.replenish(); now += 1
        r = try await turn(entry, now, sib)
        XCTAssertEqual(r.invited, ["room17"])
        XCTAssertNil(r.entry, "17개 방 모두 들어가면 대기열에서 빠진다")
        XCTAssertEqual(sib.members.count, 17)
        XCTAssertEqual(sib.inviteCalls, 17, "실패한 초대 시도 0")
    }

    /// 잔량 수치가 낡아 noKey 가 나면 그 차례는 멈춘다 · 잔량을 모르면 예전처럼 · 재시도 불가 실패는 failed · unauthorized 는 그대로 올린다.
    @MainActor
    func testStaleCountUnknownCountAndFailures() async throws {
        let e = SiblingInviteQueue.Entry(target: "t-web", rooms: ["a", "b", "c"], since: 0)
        let open: (RoomID) -> SelfService.RoomView? = { SelfService.RoomView(roomId: $0, joined: true, halted: false, pending: false, roster: []) }
        var tries = 0
        var r = try await SiblingInviteQueue.turn(e, now: Date(timeIntervalSince1970: 1), lobbyLive: { 5 }, roomView: open,
                                                  invite: { _ in tries += 1; throw InviteFailure.noKey },
                                                  isRetryable: { _ in true }, isNoKey: { ($0 as? InviteFailure) == .noKey })
        XCTAssertEqual(tries, 1, "첫 noKey 뒤 나머지는 시도하지 않는다")
        XCTAssertEqual(r.entry?.rooms, ["a", "b", "c"])
        XCTAssertEqual(r.entry?.recheckAt, 1 + SelfService.siblingLobbyRecheck)
        var invited: [RoomID] = []
        r = try await SiblingInviteQueue.turn(e, now: Date(timeIntervalSince1970: 1), lobbyLive: { nil }, roomView: open,
                                              invite: { room in invited.append(room); if room == "b" { throw InviteFailure.refused } },
                                              isRetryable: { ($0 as? InviteFailure) == .noKey }, isNoKey: { ($0 as? InviteFailure) == .noKey })
        XCTAssertEqual(invited, ["a", "b", "c"], "잔량을 모르면 제한 없이")
        XCTAssertEqual(r.invited, ["a", "c"])
        XCTAssertEqual(r.failed.map(\.room), ["b"])
        XCTAssertNil(r.entry)
        do {
            _ = try await SiblingInviteQueue.turn(e, now: Date(timeIntervalSince1970: 1), lobbyLive: { 8 }, roomView: open,
                                                  invite: { _ in throw RelayError.unauthorized }, isRetryable: { _ in true }, isNoKey: { _ in false })
            XCTFail("unauthorized must propagate")
        } catch RelayError.unauthorized {}
    }

    func testUserDefaultsQueueStoreRoundTripsAndRemovesWhenEmpty() {
        let suite = "hande-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSiblingQueueStore(defaults: defaults)
        XCTAssertTrue(store.load(device: "mom-web-a").isEmpty)
        let q = SiblingInviteQueue().enqueued(target: "mom-pc-1", rooms: ["family"], now: Date(timeIntervalSince1970: 1000))
        store.save(q, device: "mom-web-a")
        XCTAssertNotNil(defaults.data(forKey: "hande.siblingInvites.mom-web-a"))
        XCTAssertEqual(store.load(device: "mom-web-a"), q)
        XCTAssertTrue(store.load(device: "mom-pc-9").isEmpty, "기기별")
        store.save(SiblingInviteQueue(), device: "mom-web-a")
        XCTAssertNil(defaults.data(forKey: "hande.siblingInvites.mom-web-a"), "비면 키를 지운다")
        defaults.set(Data("{bad".utf8), forKey: "hande.siblingInvites.mom-web-a")
        XCTAssertTrue(store.load(device: "mom-web-a").isEmpty, "깨진 값은 빈 대기열")
    }

    func testSignatureHexReadsTheFacadeFrame() throws {
        let canonical = Data("{\"action\":\"approve-device\"}".utf8)
        let signature = Data((0..<64).map { UInt8($0) })
        var framed = Data()
        var n = UInt32(canonical.count).littleEndian
        framed.append(Data(bytes: &n, count: 4)); framed.append(canonical); framed.append(signature)
        let hex = try SelfService.signatureHex(framed: framed)
        XCTAssertEqual(hex.count, 128)
        XCTAssertTrue(hex.hasPrefix("000102030405"))
        XCTAssertTrue(hex.hasSuffix("3e3f"))
        let sliced = (Data([0]) + framed).dropFirst()   // startIndex 1 인 slice — 절대 인덱스로 읽어야 한다
        XCTAssertEqual(try SelfService.signatureHex(framed: sliced), hex, "slice 와 전체가 같은 결과")
        XCTAssertThrowsError(try SelfService.signatureHex(framed: framed.dropLast())) { XCTAssertEqual($0 as? SelfService.Failure, .signatureFrame) }
        XCTAssertThrowsError(try SelfService.signatureHex(framed: Data([1, 2])))
        XCTAssertThrowsError(try SelfService.signatureHex(framed: Data([0xff, 0xff, 0xff, 0x7f]) + signature), "길이가 본문을 넘는다")
    }

    func testFingerprintGroups() {
        XCTAssertEqual(SelfService.fingerprintGroups("abcdef0123"), "abcd ef01 23")
        XCTAssertEqual(SelfService.fingerprintGroups(" ab cd "), "abcd")
        XCTAssertEqual(SelfService.fingerprintGroups(""), "")
        XCTAssertEqual(SelfService.fingerprintGroups(String(repeating: "f", count: 64)).count, 64 + 15)
    }

    // MARK: - #616 빠진 방 주기적 재탐색(오너 D1~D3) — 웹 self-service.test.mjs 와 같은 사례

    private func view(_ room: RoomID, _ roster: [DeviceID], halted: Bool = false, synced: Bool = true, joined: Bool = true) -> SelfService.RoomView {
        SelfService.RoomView(roomId: room, joined: joined, halted: halted, pending: false, roster: roster, synced: synced)
    }

    func testRescanSiblingsAreOtherActiveDevicesOfMyActor() {
        let m = me(dev("mom-web-a"), dev("mom-iphone-b"), dev("mom-android-c", status: "revoked"), dev("dad-pc-d"), dev("mom-android-e"))
        XCTAssertEqual(SiblingRescan.siblings(me: m, device: "mom-web-a"), ["mom-android-e", "mom-iphone-b"])
        XCTAssertEqual(SiblingRescan.siblings(me: m, device: "mom-ghost-z"), [])
        XCTAssertEqual(SiblingRescan.siblings(me: me(dev("mom-web-a", status: "revoked"), dev("mom-iphone-b")), device: "mom-web-a"), [], "철회된 내가 초대하지 않는다")
        XCTAssertEqual(SiblingRescan.siblings(me: MeResponse(subject: "sub-1"), device: "mom-web-a"), [], "옛 릴레이")
        XCTAssertEqual(SiblingRescan.siblings(me: nil, device: "mom-web-a"), [])
    }

    func testRescanDueEverySixHoursOrWhenADeferredRoomRipens() {
        let t0: TimeInterval = 1_000_000_000
        XCTAssertTrue(SiblingRescan.due(.init(), now: Date(timeIntervalSince1970: t0)))
        XCTAssertFalse(SiblingRescan.due(.init(last: t0), now: Date(timeIntervalSince1970: t0 + SiblingRescan.interval - 1)))
        XCTAssertTrue(SiblingRescan.due(.init(last: t0), now: Date(timeIntervalSince1970: t0 + SiblingRescan.interval)))
        XCTAssertFalse(SiblingRescan.due(.init(last: t0, pending: ["b|r": t0]), now: Date(timeIntervalSince1970: t0 + SiblingRescan.deferral - 1)))
        XCTAssertTrue(SiblingRescan.due(.init(last: t0, pending: ["b|r": t0]), now: Date(timeIntervalSince1970: t0 + SiblingRescan.deferral)))
    }

    func testRescanSkipsRemovedHaltedAndPresentRoomsButKeepsNeverJoinedOnes() {
        var rooms = (0..<17).map { view(String(format: "r%02d", $0), ["mom-a"]) }
        rooms[3] = view("r03", ["mom-a"], halted: true)
        rooms[4] = view("r04", ["mom-a", "mom-z"])
        let turn = SiblingRescan.turn(rooms: rooms, device: "mom-a", siblings: ["mom-z"], excluded: ["mom-z": ["r00", "r01", "gone-room"]],
                                      state: .init(), now: Date(timeIntervalSince1970: 5))
        XCTAssertTrue(turn.ready)
        XCTAssertEqual(turn.enqueue.map(\.target), ["mom-z"])
        XCTAssertEqual(turn.enqueue.first?.rooms, rooms.map(\.roomId).filter { !["r00", "r01", "r03", "r04"].contains($0) })
        XCTAssertEqual(turn.enqueue.first?.rooms.count, 13)
        XCTAssertEqual(turn.state, .init(last: 5, pending: [:]))
    }

    func testRescanFailsClosedOnOldRelayAndWaitsForStaleRosters() {
        let rooms = [view("family", ["mom-a"])]
        let mixed = SiblingRescan.turn(rooms: rooms, device: "mom-a", siblings: ["mom-b", "mom-c"], excluded: ["mom-b": nil, "mom-c": []], state: .init(), now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(mixed.enqueue.map(\.target), ["mom-c"], "excluded nil(옛 릴레이) 기기는 건너뛴다")
        XCTAssertTrue(SiblingRescan.turn(rooms: rooms, device: "mom-a", siblings: ["mom-b"], excluded: [:], state: .init(), now: Date(timeIntervalSince1970: 1)).enqueue.isEmpty)
        let state = SiblingRescan.State(last: nil, pending: ["x|y": 1])
        let stale = SiblingRescan.turn(rooms: [view("a", ["mom-a"]), view("b", ["mom-a"], synced: false)], device: "mom-a", siblings: ["mom-z"],
                                       excluded: ["mom-z": []], state: state, now: Date(timeIntervalSince1970: 9))
        XCTAssertFalse(stale.ready)
        XCTAssertTrue(stale.enqueue.isEmpty)
        XCTAssertEqual(stale.state, state)
    }

    func testRescanOneInviterPerRoomLowestIdNowOthersAfterThirtyMinutes() {
        let rooms = [view("family", ["mom-a", "mom-b"]), view("solo", ["mom-b"])]
        let ex: [DeviceID: [RoomID]?] = ["mom-z": []]
        let t1 = SiblingRescan.turn(rooms: rooms, device: "mom-b", siblings: ["mom-a", "mom-z"], excluded: ex, state: .init(), now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(t1.enqueue.first?.rooms, ["solo"], "내가 유일한 내 기기인 방은 바로")
        XCTAssertEqual(t1.state.pending, ["mom-z|family": 100], "리더(mom-a)가 있는 방은 미룬다")
        let t2 = SiblingRescan.turn(rooms: rooms, device: "mom-b", siblings: ["mom-a", "mom-z"], excluded: ex, state: t1.state,
                                    now: Date(timeIntervalSince1970: 100 + SiblingRescan.deferral - 1))
        XCTAssertFalse(t2.enqueue.flatMap(\.rooms).contains("family"))
        XCTAssertEqual(t2.state.pending["mom-z|family"], 100, "처음 본 시각 유지")
        let t3 = SiblingRescan.turn(rooms: rooms, device: "mom-b", siblings: ["mom-a", "mom-z"], excluded: ex, state: t1.state,
                                    now: Date(timeIntervalSince1970: 100 + SiblingRescan.deferral))
        XCTAssertEqual(t3.enqueue.first?.rooms, ["family", "solo"])
        XCTAssertEqual(t3.state.pending, [:])
        let t4 = SiblingRescan.turn(rooms: [view("family", ["mom-a", "mom-b", "mom-z"])], device: "mom-b", siblings: ["mom-a", "mom-z"], excluded: ex,
                                    state: t1.state, now: Date(timeIntervalSince1970: 100 + SiblingRescan.deferral))
        XCTAssertTrue(t4.enqueue.isEmpty, "리더가 먼저 들였다")
        XCTAssertEqual(t4.state.pending, [:])
        let lead = SiblingRescan.turn(rooms: [view("family", ["mom-a", "mom-b"])], device: "mom-a", siblings: ["mom-b", "mom-z"], excluded: ex,
                                      state: .init(), now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(lead.enqueue.first?.rooms, ["family"])
    }

    func testRescanStoresRoundTripAndQueueKeepsOrigin() throws {
        let suite = "rescan-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSiblingRescanStore(defaults: defaults)
        XCTAssertEqual(store.load(device: "mom-a"), .init())
        store.save(.init(last: 7, pending: ["x|y": 3]), device: "mom-a")
        XCTAssertEqual(store.load(device: "mom-a"), .init(last: 7, pending: ["x|y": 3]))
        defaults.set(Data("not json".utf8), forKey: UserDefaultsSiblingRescanStore.key("mom-a"))
        XCTAssertEqual(store.load(device: "mom-a"), .init(), "깨진 값은 빈 상태")
        XCTAssertFalse(store.isOff(device: "mom-a"), "기본 켜짐")
        store.setOff(true, device: "mom-a")
        XCTAssertTrue(store.isOff(device: "mom-a"))
        XCTAssertFalse(store.isOff(device: "mom-b"), "기기별")
        store.setOff(false, device: "mom-a")
        XCTAssertFalse(store.isOff(device: "mom-a"))

        let q = SiblingInviteQueue().enqueued(target: "mom-z", rooms: ["family"], now: Date(timeIntervalSince1970: 1), origin: SiblingRescan.origin)
        XCTAssertEqual(q.entries.first?.origin, "rescan")
        let merged = SiblingInviteQueue([.init(target: "mom-z", rooms: ["a"], since: 0)]).enqueued(target: "mom-z", rooms: ["family"], now: Date(timeIntervalSince1970: 1), origin: SiblingRescan.origin)
        XCTAssertEqual(merged.entries, [.init(target: "mom-z", rooms: ["a", "family"], since: 0)], "승인 항목에 합칠 때는 원래 출처 유지")
        let queueStore = UserDefaultsSiblingQueueStore(defaults: defaults)
        queueStore.save(q, device: "mom-a")
        XCTAssertEqual(queueStore.load(device: "mom-a"), q, "origin 이 저장값을 왕복")
        let old = try JSONDecoder().decode([SiblingInviteQueue.Entry].self, from: Data(#"[{"target":"mom-z","rooms":["r"],"since":1}]"#.utf8))
        XCTAssertNil(old.first?.origin, "옛 저장값")
    }
}
