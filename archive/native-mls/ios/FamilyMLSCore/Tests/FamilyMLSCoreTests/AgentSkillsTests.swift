// #834: AgentSkills.split — 웹 tests/agent-markdown.test.mjs 「splitSkills」와 같은 표.
import XCTest
@testable import FamilyMLSCore

final class AgentSkillsTests: XCTestCase {
    func testSplitsTheLastSkillLine() {
        let r = AgentSkills.split("답입니다.\n\n📘 gh-pr-flow · wiki-record")
        XCTAssertEqual(r.body, "답입니다.")
        XCTAssertEqual(r.skills, ["gh-pr-flow", "wiki-record"])
        let md = AgentSkills.split("## 제목\n- 항목\n\n📘 plugin:skill\n")
        XCTAssertEqual(md.body, "## 제목\n- 항목")
        XCTAssertEqual(md.skills, ["plugin:skill"])
        let choice = "**[답변 필요]** 하나만 선택\n1. (권장) 진행\n2. 보류"
        XCTAssertEqual(AgentSkills.split("\(choice)\n\n📘 gh-pr-flow").body, choice)
    }

    func testLeavesOtherTextAlone() {
        let many = (0...AgentSkills.maxSkills).map { "s\($0)" }.joined(separator: " · ")
        for text in [
            "답\n📘 gh-pr-flow",
            "📘 gh-pr-flow",
            "답\n\n📘 gh-pr-flow\n\n덧붙임",
            "답\n\n📘 bad name",
            "답\n\n📘 a, b",
            "답\n\n📘 ",
            "답\n\n📘 \(many)",
            "답\n\n📘 " + String(repeating: "x", count: 65),
            "답\n\n📘 스킬",
        ] {
            let r = AgentSkills.split(text)
            XCTAssertEqual(r.body, text, text)
            XCTAssertEqual(r.skills, [], text)
        }
    }

    func testSkillNameRule() {
        XCTAssertTrue(AgentSkills.isSkillName(String(repeating: "x", count: 64)))
        XCTAssertTrue(AgentSkills.isSkillName("a.b_c:d-e"))
        XCTAssertFalse(AgentSkills.isSkillName("-lead"))
        XCTAssertFalse(AgentSkills.isSkillName(""))
    }
}
