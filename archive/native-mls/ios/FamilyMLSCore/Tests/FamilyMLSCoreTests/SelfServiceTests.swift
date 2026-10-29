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
}
