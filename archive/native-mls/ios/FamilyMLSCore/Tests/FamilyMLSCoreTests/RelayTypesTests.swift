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
        let reg = try JSONEncoder().encode(PushRegistration(device: "owner-iphone", apnsToken: Data([1]), topic: "com.example.familychat.ios"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reg) as? [String: Any])
        XCTAssertEqual(object["apns_token"] as? String, "AQ==")
        XCTAssertEqual(object["topic"] as? String, "com.example.familychat.ios")
    }

    func testEngineMethodWireNames() {
        XCTAssertEqual(EngineMethod.keyPackage.rawValue, "key_package")
        XCTAssertEqual(EngineMethod.inviteWithCommit.rawValue, "invite_with_commit")
        XCTAssertEqual(EngineMethod.signApproval.rawValue, "sign_approval")
        XCTAssertEqual(EngineMethod.allCases.count, 20)
    }
}
