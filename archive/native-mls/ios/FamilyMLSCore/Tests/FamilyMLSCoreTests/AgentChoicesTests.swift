import XCTest
@testable import FamilyMLSCore

/// agent-choices-v1(#620): 공유 벡터(웹·안드로이드와 같은 답) + 타임라인 상태.
final class AgentChoicesTests: XCTestCase {
    // MARK: - fixture loading (#filePath walk-up)

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "AgentChoicesTests.fixture", code: 1,
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

    /// JSON 숫자 배열 → [Int], null(또는 배열 아님) → nil.
    private func ints(_ raw: Any?) -> [Int]? {
        guard let raw, !(raw is NSNull), let array = raw as? [Any] else { return nil }
        return array.compactMap { ($0 as? NSNumber)?.intValue }
    }

    // MARK: - shared vectors

    func testParseVectors() throws {
        let root = try loadRoot()
        let vectors = try XCTUnwrap(root["parse"] as? [[String: Any]], "fixture must have a parse array")
        XCTAssertFalse(vectors.isEmpty)
        for (idx, raw) in vectors.enumerated() {
            let name = (raw["name"] as? String) ?? "parse[\(idx)]"
            let text = try XCTUnwrap(raw["text"] as? String, "[\(name)] text")
            let got = AgentChoices.parse(text)
            guard let expected = raw["expected"] as? [String: Any] else {
                XCTAssertNil(got, "[\(name)] expected null, got \(String(describing: got))")
                continue
            }
            let rawItems = try XCTUnwrap(expected["items"] as? [[String: Any]], "[\(name)] expected.items")
            let items = try rawItems.map { item in
                AgentChoices.Item(number: try XCTUnwrap(int(item["number"]), "[\(name)] item.number"),
                                  label: try XCTUnwrap(item["label"] as? String, "[\(name)] item.label"))
            }
            let want = AgentChoices(items: items, recommended: int(expected["recommended"]))
            XCTAssertEqual(got, want, "[\(name)]")
        }
    }

    func testReplyVectors() throws {
        let root = try loadRoot()
        let vectors = try XCTUnwrap(root["reply"] as? [[String: Any]], "fixture must have a reply array")
        XCTAssertFalse(vectors.isEmpty)
        for (idx, raw) in vectors.enumerated() {
            let text = try XCTUnwrap(raw["text"] as? String, "reply[\(idx)] text")
            let count = try XCTUnwrap(int(raw["count"]), "reply[\(idx)] count")
            // #624: expected = 번호 배열(오름차순·중복 없음) 또는 null.
            XCTAssertEqual(AgentChoices.reply(text, count: count), ints(raw["expected"]), "reply[\(idx)] \(text.debugDescription)")
        }
    }

    func testComposeVectors() throws {
        let root = try loadRoot()
        let vectors = try XCTUnwrap(root["compose"] as? [[String: Any]], "fixture must have a compose array")
        XCTAssertFalse(vectors.isEmpty)
        for (idx, raw) in vectors.enumerated() {
            let numbers = try XCTUnwrap(ints(raw["numbers"]), "compose[\(idx)] numbers")
            let expected = try XCTUnwrap(raw["expected"] as? String, "compose[\(idx)] expected")
            XCTAssertEqual(AgentChoices.compose(numbers), expected, "compose[\(idx)] \(numbers)")
            // 보낸 글은 다시 같은 번호 집합으로 읽혀야 한다(answered 왕복).
            XCTAssertEqual(AgentChoices.reply(expected, count: 9), Array(Set(numbers)).sorted(), "compose[\(idx)] round-trip")
        }
    }

    // MARK: - timeline state

    let roster = AgentRoster(setting: "bot")
    let me: DeviceID = "owner-iphone-27a879"
    let myPC: DeviceID = "owner-pc"
    let other: DeviceID = "jungin-iphone-1b89e3"
    let bot: DeviceID = "bot-gongmyoung"
    let choices = "다음 단계\n1. 병합\n2. 보류\n3. 롤백"

    func rec(_ seq: Int64, _ device: DeviceID, _ body: String, kind: MessageRecord.Kind = .text) -> MessageRecord {
        MessageRecord(room: "family-acc", seq: seq, senderDevice: device, clientId: "c\(seq)", kind: kind, body: body,
                      attachment: nil, receivedAt: Date(timeIntervalSince1970: 0), decryptedBy: .app)
    }

    func testLastAgentChoiceIsOpen() {
        let cards = AgentChoices.cards([rec(1, me, "어떻게 할까"), rec(2, bot, choices)], roster: roster, myDevice: me)
        XCTAssertEqual(cards[2]?.state, .open)
        XCTAssertEqual(cards[2]?.choices.items.map(\.label), ["병합", "보류", "롤백"])
        XCTAssertNil(cards[1])
    }

    func testMyNumberReplyAnswersIncludingOtherDeviceAndManualTyping() {
        XCTAssertEqual(AgentChoices.states([rec(1, bot, choices), rec(2, me, "2")], roster: roster, myDevice: me)[1], .answered([2]))
        XCTAssertEqual(AgentChoices.states([rec(1, bot, choices), rec(2, me, " 3번. ")], roster: roster, myDevice: me)[1], .answered([3]))
        // 같은 사람의 다른 기기(PC)에서 보낸 답도 내 답(MessageRecord.isMine).
        XCTAssertEqual(AgentChoices.states([rec(1, bot, choices), rec(2, myPC, "1")], roster: roster, myDevice: me)[1], .answered([1]))
        // 답 뒤에 에이전트가 이어 말해도 「바로 다음」이 내 답이면 answered.
        let after = [rec(1, bot, choices), rec(2, me, "1"), rec(3, bot, "병합하겠습니다.")]
        XCTAssertEqual(AgentChoices.states(after, roster: roster, myDevice: me)[1], .answered([1]))
    }

    /// #624 복수 선택: 카드가 보낸 `1, 3` 이나 손으로 친 `3,1` · `1 → 2 → 3` 도 answered(번호 목록, 오름차순·중복 없음).
    func testMultiNumberReplyAnswers() {
        XCTAssertEqual(AgentChoices.states([rec(1, bot, choices), rec(2, me, AgentChoices.compose([3, 1]))], roster: roster, myDevice: me)[1],
                       .answered([1, 3]))
        XCTAssertEqual(AgentChoices.states([rec(1, bot, choices), rec(2, me, "3,1")], roster: roster, myDevice: me)[1], .answered([1, 3]))
        XCTAssertEqual(AgentChoices.states([rec(1, bot, choices), rec(2, me, "1 → 2 → 3")], roster: roster, myDevice: me)[1],
                       .answered([1, 2, 3]))
        XCTAssertEqual(AgentChoices.states([rec(1, bot, choices), rec(2, myPC, "2번, 2번")], roster: roster, myDevice: me)[1], .answered([2]))
        // 하나라도 범위 밖 · 끝이 구분자 · 다른 사람의 복수 답 → closed.
        for next in [rec(2, me, "1, 4"), rec(2, me, "1,"), rec(2, other, "1, 3")] {
            XCTAssertEqual(AgentChoices.states([rec(1, bot, choices), next], roster: roster, myDevice: me)[1], .closed, next.body)
        }
    }

    func testOtherFollowUpsClose() {
        // 범위 밖 번호 · 일반 글 · 다른 사람의 답 · 에이전트의 다음 글 · 첨부 → closed.
        for next in [rec(2, me, "4"), rec(2, me, "병합해 줘"), rec(2, other, "1"), rec(2, bot, "더 할 말"),
                     rec(2, me, "photo.jpg", kind: .attachment)] {
            XCTAssertEqual(AgentChoices.states([rec(1, bot, choices), next], roster: roster, myDevice: me)[1], .closed, next.body)
        }
        // 「바로 다음」만 본다 — 사이에 다른 글이 끼면 그 뒤 내 번호는 답이 아니다.
        let late = [rec(1, bot, choices), rec(2, other, "음"), rec(3, me, "1")]
        XCTAssertEqual(AgentChoices.states(late, roster: roster, myDevice: me)[1], .closed)
    }

    func testSystemRowsAreSkipped() {
        let records = [rec(1, bot, choices), rec(2, "relay", "멤버 추가", kind: .system), rec(3, me, "2")]
        XCTAssertEqual(AgentChoices.states(records, roster: roster, myDevice: me)[1], .answered([2]))
        let openAfterSystem = [rec(1, bot, choices), rec(2, "relay", "멤버 추가", kind: .system)]
        XCTAssertEqual(AgentChoices.states(openAfterSystem, roster: roster, myDevice: me)[1], .open)
    }

    func testOnlyAgentTextWithChoicesGetsACard() {
        // 사람이 쓴 같은 글은 카드가 아니다 · 선택지 없는 에이전트 글도 아니다.
        XCTAssertTrue(AgentChoices.cards([rec(1, other, choices)], roster: roster, myDevice: me).isEmpty)
        XCTAssertTrue(AgentChoices.cards([rec(1, bot, "설치 순서입니다.\n1. a\n2. b")], roster: roster, myDevice: me).isEmpty)
        // 앞선 선택지는 뒤 선택지가 와도 각자 판정한다.
        let records = [rec(1, bot, choices), rec(2, me, "1"), rec(3, bot, "어느 쪽?\n1. 가\n2. 나")]
        let states = AgentChoices.states(records, roster: roster, myDevice: me)
        XCTAssertEqual(states[1], .answered([1]))
        XCTAssertEqual(states[3], .open)
    }

    func testEmptyDeviceNeverAnswers() {
        XCTAssertEqual(AgentChoices.states([rec(1, bot, choices), rec(2, me, "1")], roster: roster, myDevice: "")[1], .closed)
    }

    /// 받은 글은 신뢰하지 않는다 — 아주 긴 숫자열도 넘치지 않고 그냥 선택지가 아니다.
    func testLongDigitRunsDoNotOverflow() {
        let long = String(repeating: "9", count: 40)
        XCTAssertNil(AgentChoices.parse("선택?\n\(long). 가\n\(long). 나"))
        XCTAssertNil(AgentChoices.reply(long, count: 3))
        XCTAssertEqual(AgentChoices.parse("권장: \(long)번\n선택?\n1. 가\n2. 나")?.recommended, nil)
    }

    func testLabelLookup() {
        let parsed = AgentChoices.parse(choices)
        XCTAssertEqual(parsed?.label(of: 2), "보류")
        XCTAssertNil(parsed?.label(of: 9))
    }
}
