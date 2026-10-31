import XCTest
@testable import FamilyMLSCore

/// agent-choices-v1 §3.1(#629): 선택지 카드 키보드 단축키 — 공유 벡터 `keys`(웹 `choiceKeyAction` 과 같은 답).
final class AgentChoiceKeysTests: XCTestCase {
    // MARK: - fixture loading (#filePath walk-up, AgentChoicesTests 와 같은 방식)

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "AgentChoiceKeysTests.fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func fixtureURL() throws -> URL {
        let relative = "archive/native-mls/tests/fixtures/agent-choices-vectors.json"
        var dir = URL(fileURLWithPath: #filePath)
        var searched: [String] = []
        for _ in 0..<10 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent(relative)
            searched.append(candidate.path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        XCTFail("agent-choices-vectors.json not found — searched:\n\(searched.joined(separator: "\n"))")
        throw fixtureError("fixture not found")
    }

    private func loadRoot() throws -> [String: Any] {
        let data = try Data(contentsOf: try fixtureURL())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], "fixture root must be an object")
    }

    private func int(_ raw: Any?) -> Int? {
        guard let raw, !(raw is NSNull) else { return nil }
        return (raw as? NSNumber)?.intValue
    }

    private func bool(_ raw: Any?) -> Bool {
        guard let raw, !(raw is NSNull) else { return false }
        if let flag = raw as? Bool { return flag }
        return (raw as? NSNumber)?.boolValue ?? false
    }

    private func input(_ raw: [String: Any], name: String) throws -> AgentChoiceKeys.Input {
        let keyName = try XCTUnwrap(raw["key"] as? String, "\(name): input.key")
        let key: AgentChoiceKeys.Key
        switch keyName {
        case "digit": key = .digit(try XCTUnwrap(int(raw["digit"]), "\(name): input.digit"))
        case "enter": key = .enter
        case "other": key = .other
        default: throw fixtureError("\(name): unknown key \(keyName)")
        }
        return AgentChoiceKeys.Input(key, option: bool(raw["alt"]), control: bool(raw["ctrl"]), command: bool(raw["meta"]),
                                     shift: bool(raw["shift"]), composing: bool(raw["composing"]))
    }

    private func card(_ raw: Any?, name: String) throws -> AgentChoiceKeys.Card? {
        guard let raw, !(raw is NSNull) else { return nil }
        let object = try XCTUnwrap(raw as? [String: Any], "\(name): card must be an object or null")
        let selected = (object["selected"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        return AgentChoiceKeys.Card(count: try XCTUnwrap(int(object["count"]), "\(name): card.count"),
                                    selected: Set(selected), enabled: bool(object["enabled"]))
    }

    private func expected(_ raw: Any?, name: String) throws -> AgentChoiceKeys.Action? {
        guard let raw, !(raw is NSNull) else { return nil }
        let object = try XCTUnwrap(raw as? [String: Any], "\(name): expected must be an object or null")
        switch object["action"] as? String {
        case "toggle": return .toggle(try XCTUnwrap(int(object["number"]), "\(name): expected.number"))
        case "send": return .send
        default: throw fixtureError("\(name): unknown expected action")
        }
    }

    // MARK: - shared vectors

    func testKeyVectors() throws {
        let root = try loadRoot()
        let vectors = try XCTUnwrap(root["keys"] as? [[String: Any]], "fixture must have a keys array")
        XCTAssertEqual(vectors.count, 18)
        for (idx, raw) in vectors.enumerated() {
            let name = (raw["name"] as? String) ?? "keys[\(idx)]"
            let rawInput = try XCTUnwrap(raw["input"] as? [String: Any], "\(name): input")
            let pressed = try input(rawInput, name: name)
            let openCard = try card(raw["card"], name: name)
            let want = try expected(raw["expected"], name: name)
            XCTAssertEqual(AgentChoiceKeys.decide(pressed, card: openCard), want, name)
        }
    }

    // MARK: - edges beyond the vectors

    func testDigitOutsideOneToNineIsNotIntercepted() {
        let card = AgentChoiceKeys.Card(count: 9, selected: [], enabled: true)
        XCTAssertNil(AgentChoiceKeys.decide(.init(.digit(0), option: true), card: card))
        XCTAssertNil(AgentChoiceKeys.decide(.init(.digit(10), option: true), card: card))
    }
}
