import XCTest
@testable import FamilyMLSCore

/// alert-refs-v1: 공유 벡터(웹·안드로이드와 같은 답) + 이동 대상.
final class AlertRefsTests: XCTestCase {
    private func fixture() throws -> [[String: Any]] {
        let relative = "archive/native-mls/tests/fixtures/alert-refs-vectors.json"
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
                return try XCTUnwrap(root["parse"] as? [[String: Any]])
            }
        }
        XCTFail("alert-refs-vectors.json not found")
        return []
    }

    func testParseVectors() throws {
        let vectors = try fixture()
        XCTAssertGreaterThanOrEqual(vectors.count, 10)
        for raw in vectors {
            let name = raw["name"] as? String ?? "?"
            let text = try XCTUnwrap(raw["text"] as? String)
            let got = AlertRefs.parse(text)
            XCTAssertEqual(got.selfID, raw["self"] as? String, name)
            XCTAssertEqual(got.refs.map(\.id), try XCTUnwrap(raw["refs"] as? [String]), name)
            let scalars = Array(text.unicodeScalars)
            for ref in got.refs {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[ref.start..<ref.end])
                XCTAssertEqual(String(view), "#\(ref.id)", name)
            }
        }
    }

    func testURLRoundTrip() throws {
        let url = try XCTUnwrap(AlertRefs.url(for: "6c9kzj"))
        XCTAssertEqual(url.absoluteString, "hande-alert://6c9kzj")
        XCTAssertEqual(AlertRefs.id(from: url), "6c9kzj")
        XCTAssertNil(AlertRefs.id(from: try XCTUnwrap(URL(string: "https://6c9kzj"))))
        XCTAssertNil(AlertRefs.id(from: try XCTUnwrap(URL(string: "hande-alert://6c9kz"))))
    }

    private func rec(_ seq: Int64, _ device: DeviceID, _ body: String) -> MessageRecord {
        MessageRecord(room: "fleet-alerts", seq: seq, senderDevice: device, clientId: "c\(seq)", kind: .text, body: body,
                      attachment: nil, receivedAt: Date(timeIntervalSince1970: 0), decryptedBy: .app)
    }

    func testTargetIsTheLatestFleetAlertWithThatSelfID() {
        let records = [
            rec(1, "fleet-bot", "[서서] #6c9kzj 첫 알림"),
            rec(2, "owner-iphone-1", "#6c9kzj 사람이 쓴 글"),
            rec(3, "card-bot", "#6c9kzj 카드 봇"),
            rec(4, "fleet-bot", "#69pgri ⏰ 재통지 1/3 #6c9kzj"),
        ]
        XCTAssertEqual(AlertRefs.target(id: "6c9kzj", in: records, from: 4), 1)
        XCTAssertEqual(AlertRefs.target(id: "69pgri", in: records, from: 9), 4)
        XCTAssertNil(AlertRefs.target(id: "69pgri", in: records, from: 4))
        XCTAssertNil(AlertRefs.target(id: "zzzzzz", in: records))
        XCTAssertEqual(AlertRefs.target(id: "6c9kzj", in: records + [rec(5, "fleet-bot", "#6c9kzj 나중 글")], from: 4), 5)
    }
}
