// 릴레이 와이어 타입이 server.go 의 JSON 과 글자 그대로 맞는지 — 고정 샘플로 디코드/인코드.
import XCTest
@testable import FamilyMLSCore

final class RelayTypesTests: XCTestCase {
    func testEventsPageDecodesServerShape() throws {
        let json = """
        {"epoch":4,"revision":7,"events":[{"seq":12,"device":"owner-pc","client_id":"owner-pc:12","kind":"application","epoch":4,"bytes":"AQID","sha256":"abc","created_at":1700000000}],"next_after":12,"cursor":11,"first_seq":3,"members":[{"device":"owner-pc","actor":"owner"},{"device":"bot-1","actor":"bot"}]}
        """
        let page = try JSONDecoder().decode(EventsPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.epoch, 4); XCTAssertEqual(page.revision, 7); XCTAssertEqual(page.nextAfter, 12)
        XCTAssertEqual(page.firstSeq, 3); XCTAssertEqual(page.cursor, 11)
        XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.events[0].kind, .application)
        XCTAssertEqual(page.events[0].clientId, "owner-pc:12")
        XCTAssertEqual(page.events[0].bytes, Data([1, 2, 3]))
        XCTAssertEqual(page.members?.map(\.actor), ["owner", "bot"])
        XCTAssertNil(page.typing, "a relay from before #562 omits typing")
        XCTAssertNil(page.readSeq, "a relay from before #571 omits read_seq")
    }

    /// #571 B(server/read.go): `GET /events` 의 `read_seq`(같은 사람의 읽음 위치, 없으면 0) · `POST /read` 바디 `{device, seq}` · 응답 `{read_seq}`.
    func testReadWireShape() throws {
        let page = try JSONDecoder().decode(EventsPage.self, from: Data(#"{"epoch":1,"revision":1,"events":[],"next_after":0,"typing":[],"read_seq":12}"#.utf8))
        XCTAssertEqual(page.readSeq, 12)
        let none = try JSONDecoder().decode(EventsPage.self, from: Data(#"{"epoch":1,"revision":1,"events":[],"next_after":0,"read_seq":0}"#.utf8))
        XCTAssertEqual(none.readSeq, 0, "0 = nothing read yet (the key is always present on a #571 relay)")
        let encoded = try JSONEncoder().encode(ReadPost(device: "owner-iphone-1", seq: 12))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["device", "seq"], "strictJSON — no other keys")
        XCTAssertEqual(object["device"] as? String, "owner-iphone-1")
        XCTAssertEqual(try JSONDecoder().decode(ReadPost.self, from: encoded), ReadPost(device: "owner-iphone-1", seq: 12))
        XCTAssertEqual(try JSONDecoder().decode(ReadResponse.self, from: Data(#"{"read_seq":15}"#.utf8)), ReadResponse(readSeq: 15))
    }

    /// #562(server/typing.go): `GET /events` 의 `typing`(다른 기기, 정렬, 절대 null 아님) · `POST /typing` 바디 `{device, clear}`.
    func testTypingWireShape() throws {
        let json = """
        {"epoch":1,"revision":1,"events":[],"next_after":0,"typing":["mom-iphone-1","owner-pc"]}
        """
        let page = try JSONDecoder().decode(EventsPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.typing, ["mom-iphone-1", "owner-pc"])
        let empty = try JSONDecoder().decode(EventsPage.self, from: Data(#"{"epoch":1,"revision":1,"events":[],"next_after":0,"typing":[]}"#.utf8))
        XCTAssertEqual(empty.typing, [])
        let encoded = try JSONEncoder().encode(TypingPost(device: "owner-iphone-1", clear: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["device", "clear"], "strictJSON — no other keys")
        XCTAssertEqual(object["device"] as? String, "owner-iphone-1")
        let decoded = try JSONDecoder().decode(TypingPost.self, from: encoded)
        XCTAssertEqual(decoded, TypingPost(device: "owner-iphone-1", clear: true))
    }

    func testEventPostEncodesSnakeCaseAndBase64() throws {
        let post = EventPost(device: "owner-iphone", clientId: "owner-iphone:1", kind: .welcome, epoch: 2, revision: 5, groupId: "g1", targets: ["owner-pc"], members: [MemberWire(device: "owner-iphone", actor: "owner")], bytes: Data([255, 0]))
        let encoded = try JSONEncoder().encode(post)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["client_id"] as? String, "owner-iphone:1")
        XCTAssertEqual(object["group_id"] as? String, "g1")
        XCTAssertEqual(object["kind"] as? String, "welcome")
        XCTAssertEqual(object["bytes"] as? String, "/wA=")
        XCTAssertEqual((object["targets"] as? [String]), ["owner-pc"])
        XCTAssertEqual(((object["members"] as? [[String: Any]])?.first?["actor"]) as? String, "owner")
        XCTAssertNil(object["clientId"], "camelCase keys must never reach the wire")
    }

    func testErrorBodyAndCodes() throws {
        let body = try JSONDecoder().decode(RelayErrorBody.self, from: Data(#"{"error":"cas_mismatch","epoch":9,"revision":3}"#.utf8))
        XCTAssertEqual(RelayErrorCode(rawValue: body.error), .casMismatch)
        XCTAssertEqual(body.epoch, 9); XCTAssertEqual(body.revision, 3)
        let plain = try JSONDecoder().decode(RelayErrorBody.self, from: Data(#"{"error":"device_subject_mismatch"}"#.utf8))
        XCTAssertEqual(RelayErrorCode(rawValue: plain.error), .deviceSubjectMismatch)
        XCTAssertNil(plain.epoch)
    }

    func testExtensionTypes() throws {
        let rooms = try JSONDecoder().decode(RoomsResponse.self, from: Data(#"{"rooms":[{"room":"family","epoch":1,"revision":2,"member":true,"keypackages_outstanding":0,"closed":false}]}"#.utf8))
        XCTAssertEqual(rooms.rooms.first?.room, "family")
        XCTAssertEqual(rooms.rooms.first?.member, true)
        let reg = try JSONEncoder().encode(PushRegistration(device: "owner-iphone", apnsToken: Data([1]), topic: "com.seoyoon-family.hande"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reg) as? [String: Any])
        XCTAssertEqual(object["apns_token"] as? String, "AQ==")
        XCTAssertEqual(object["topic"] as? String, "com.seoyoon-family.hande")
    }

    /// 로비(server/lobby.go, #380 P5-1): status · welcomes · 게시 응답의 `live`(옛 릴레이에는 없다 → nil).
    func testLobbyTypesDecodeServerShape() throws {
        let status = try JSONDecoder().decode(LobbyStatus.self, from: Data(#"{"device":"owner-iphone-1","live":3,"max":8,"ttl_seconds":2592000}"#.utf8))
        XCTAssertEqual(status, LobbyStatus(device: "owner-iphone-1", live: 3, max: 8, ttlSeconds: 2_592_000))
        let welcomes = try JSONDecoder().decode(LobbyWelcomes.self, from: Data(
            #"{"welcomes":[{"room":"ops-yukson","seq":2,"epoch":1,"created_at":1700000000}]}"#.utf8))
        XCTAssertEqual(welcomes.welcomes, [PendingWelcome(room: "ops-yukson", seq: 2, epoch: 1, createdAt: 1_700_000_000)])
        XCTAssertNil(welcomes.welcomes.first?.keyPackageRef, "a relay from before #518 omits key_package_ref")
        let withRef = try JSONDecoder().decode(LobbyWelcomes.self, from: Data(
            #"{"welcomes":[{"room":"ops-yukson","seq":2,"epoch":1,"created_at":1700000000,"key_package_ref":"ab12"}]}"#.utf8))
        XCTAssertEqual(withRef.welcomes, [PendingWelcome(room: "ops-yukson", seq: 2, epoch: 1, createdAt: 1_700_000_000, keyPackageRef: "ab12")])
        let empty = try JSONDecoder().decode(LobbyWelcomes.self, from: Data(#"{"welcomes":[]}"#.utf8))
        XCTAssertEqual(empty.welcomes, [])
        let withLive = try JSONDecoder().decode(KeyPackagesResponse.self, from: Data(#"{"stored":2,"duplicates":0,"live":5}"#.utf8))
        XCTAssertEqual(withLive, KeyPackagesResponse(stored: 2, duplicates: 0, live: 5))
        let legacy = try JSONDecoder().decode(KeyPackagesResponse.self, from: Data(#"{"stored":1,"duplicates":0}"#.utf8))
        XCTAssertNil(legacy.live, "a relay from before #381 omits live")
        let deleted = try JSONDecoder().decode(LobbyDeleteResponse.self, from: Data(#"{"device":"owner-iphone-1","deleted":2}"#.utf8))
        XCTAssertEqual(deleted, LobbyDeleteResponse(device: "owner-iphone-1", deleted: 2), "#389 lobby.go lobbyDeleteResponse")
        XCTAssertEqual(RelayErrorCode(rawValue: "device_not_allowed"), .deviceNotAllowed)
        XCTAssertEqual(RelayErrorCode(rawValue: "key_package_limit"), .keyPackageLimit)
        XCTAssertEqual(RelayErrorCode(rawValue: "no_live_key_package"), .noLiveKeyPackage)
    }

    func testEngineMethodWireNames() {
        XCTAssertEqual(EngineMethod.keyPackage.rawValue, "key_package")
        XCTAssertEqual(EngineMethod.inviteWithCommit.rawValue, "invite_with_commit")
        XCTAssertEqual(EngineMethod.signApproval.rawValue, "sign_approval")
        XCTAssertEqual(EngineMethod.signRoles.rawValue, "sign_roles", "#574 ios-ffi METHODS")
        XCTAssertEqual(EngineMethod.allCases.count, 21)
    }

    /// 기기 셀프서비스(#574, server/devices.go · me.go · lobby.go): 후보 게시/목록 · 승인/역할 증거 · commit 응답 · /v2/me · Welcome 의 `from`.
    func testDeviceSelfServiceWireShapes() throws {
        let key = String(repeating: "ab", count: 32), fp = String(repeating: "cd", count: 32)
        let post = try JSONEncoder().encode(DeviceCandidatePost(deviceId: "mom-iphone-1", actor: "mom", signingKey: key, fingerprint: fp))
        let postObject = try XCTUnwrap(JSONSerialization.jsonObject(with: post) as? [String: Any])
        XCTAssertEqual(Set(postObject.keys), ["device_id", "actor", "signing_key", "fingerprint"], "strictJSON — subject 는 릴레이가 JWT 에서 읽는다")
        let posted = try JSONDecoder().decode(DeviceCandidatePosted.self, from: Data(
            #"{"device_id":"mom-iphone-1","fingerprint":"\#(fp)","policy_revision":7,"expires_at":1700000600}"#.utf8))
        XCTAssertEqual(posted, DeviceCandidatePosted(deviceId: "mom-iphone-1", fingerprint: fp, policyRevision: 7, expiresAt: 1_700_000_600))
        let list = try JSONDecoder().decode(DeviceCandidates.self, from: Data(
            #"{"policy_revision":7,"candidates":[{"device_id":"mom-iphone-1","actor":"mom","subject":"sub-1","signing_key":"\#(key)","fingerprint":"\#(fp)","created_at":1,"expires_at":601}]}"#.utf8))
        XCTAssertEqual(list, DeviceCandidates(policyRevision: 7, candidates: [
            DeviceCandidate(deviceId: "mom-iphone-1", actor: "mom", subject: "sub-1", signingKey: key, fingerprint: fp, createdAt: 1, expiresAt: 601)]))
        XCTAssertEqual(try JSONDecoder().decode(DeviceCandidates.self, from: Data(#"{"policy_revision":7,"candidates":[]}"#.utf8)).candidates, [])

        let approval = try JSONEncoder().encode(DeviceApprovalEvidence(deviceId: "mom-iphone-1", actor: "mom", subject: "sub-1", signingKey: key, baseRevision: 7,
                                                                       signature: String(repeating: "ff", count: 64), fingerprint: fp, approvedBy: "mom-web-a"))
        let approvalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: approval) as? [String: Any])
        XCTAssertEqual(Set(approvalObject.keys), ["device_id", "actor", "subject", "signing_key", "base_revision", "signature", "fingerprint", "approved_by"],
                       "devicepolicy.AddDeviceEvidence — action·acceptance 없음")
        XCTAssertEqual(approvalObject["base_revision"] as? Int, 7)
        let roles = try JSONEncoder().encode(DeviceRolesEvidence(deviceId: "mom-iphone-1", actor: "mom", roles: [], baseRevision: 8,
                                                                 signature: String(repeating: "ee", count: 64), approvedBy: "mom-web-a"))
        let rolesObject = try XCTUnwrap(JSONSerialization.jsonObject(with: roles) as? [String: Any])
        XCTAssertEqual(Set(rolesObject.keys), ["device_id", "actor", "roles", "base_revision", "signature", "approved_by"], "devicepolicy.RolesEvidence")
        XCTAssertEqual(rolesObject["roles"] as? [String], [], "빈 배열 = 역할 없음(null 금지)")
        XCTAssertEqual(try JSONDecoder().decode(DevicePolicyCommit.self, from: Data(#"{"device_id":"mom-iphone-1","approved_by":"mom-web-a","revision":8}"#.utf8)),
                       DevicePolicyCommit(deviceId: "mom-iphone-1", approvedBy: "mom-web-a", revision: 8))
        XCTAssertEqual(try JSONDecoder().decode(DevicePolicyCommit.self, from: Data(
            #"{"device_id":"mom-iphone-1","roles":["registrar"],"approved_by":"mom-web-a","revision":9}"#.utf8)).roles, ["registrar"])

        let me = try JSONDecoder().decode(MeResponse.self, from: Data(
            #"{"subject":"sub-1","policy_revision":7,"devices":[{"device_id":"mom-web-a","actor":"mom","fingerprint":"\#(fp)","status":"active","acceptance":"operator","roles":["registrar"]},{"device_id":"mom-old","actor":"mom","fingerprint":"\#(fp)","status":"revoked","acceptance":"trusted-device-fingerprint","roles":[]}]}"#.utf8))
        XCTAssertEqual(me, MeResponse(subject: "sub-1", policyRevision: 7, devices: [
            MeDevice(deviceId: "mom-web-a", actor: "mom", fingerprint: fp, status: "active", acceptance: "operator", roles: ["registrar"]),
            MeDevice(deviceId: "mom-old", actor: "mom", fingerprint: fp, status: "revoked", acceptance: "trusted-device-fingerprint", roles: [])]))
        let legacy = try JSONDecoder().decode(MeResponse.self, from: Data(#"{"subject":"sub-1"}"#.utf8))
        XCTAssertEqual(legacy, MeResponse(subject: "sub-1"), "기기 저장소가 없는 옛 릴레이는 subject 만")
        XCTAssertNil(legacy.policyRevision); XCTAssertNil(legacy.devices)
        let noRoles = try JSONDecoder().decode(MeDevice.self, from: Data(#"{"device_id":"mom-x","actor":"mom"}"#.utf8))
        XCTAssertEqual(noRoles.roles, [], "roles 가 빠져도(방어) 빈 목록")

        let welcome = try JSONDecoder().decode(LobbyWelcomes.self, from: Data(
            #"{"welcomes":[{"room":"family","seq":4,"epoch":2,"created_at":1700000000,"key_package_ref":"ab12","from":"mom-web-a"}]}"#.utf8)).welcomes
        XCTAssertEqual(welcome, [PendingWelcome(room: "family", seq: 4, epoch: 2, createdAt: 1_700_000_000, keyPackageRef: "ab12", from: "mom-web-a")])
        XCTAssertNil(try JSONDecoder().decode(PendingWelcome.self, from: Data(#"{"room":"family","seq":4,"epoch":2,"created_at":0}"#.utf8)).from,
                     "a relay from before #574 omits from")

        let stale = try JSONDecoder().decode(RelayErrorBody.self, from: Data(#"{"error":"stale_revision","detail":"revision 7 is not current","revision":9}"#.utf8))
        XCTAssertEqual(stale.detail, "revision 7 is not current"); XCTAssertEqual(stale.revision, 9)
        XCTAssertEqual(RelayErrorCode(rawValue: stale.error), .staleRevision)
        XCTAssertEqual(RelayErrorCode(rawValue: "approval_rejected"), .approvalRejected)
        XCTAssertEqual(RelayErrorCode(rawValue: "device_exists"), .deviceExists)
        XCTAssertEqual(RelayErrorCode(rawValue: "first_device_out_of_band"), .firstDeviceOutOfBand)
    }
}
