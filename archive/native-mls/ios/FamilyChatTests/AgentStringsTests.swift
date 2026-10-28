import XCTest
import FamilyMLSCore
@testable import FamilyChat

/// #405 P1: 승인 버튼이 보내는 글은 봇이 알아듣는 형식이어야 하고(native-mls-bot `parse_approval_reply`), 이름 조사는 받침을 따른다.
final class AgentStringsTests: XCTestCase {
    func testApprovalButtonsSendTheBotsReplyFormat() {
        XCTAssertEqual(Strings.approvalReply(3, allow: true), "승인 3")
        XCTAssertEqual(Strings.approvalReply(12, allow: false), "거절 12")
    }

    func testSubjectParticleFollowsTheFinalConsonant() {
        XCTAssertEqual(Strings.agentThinking("공명"), "공명이 생각하는 중")
        XCTAssertEqual(Strings.approvalTitle("루나"), "루나가 허락을 구합니다")
        XCTAssertEqual(Strings.subjectParticle("newnode"), "이(가)")
    }

    func testSenderLabelUsesNamesAndDeviceKind() {
        XCTAssertEqual(Strings.senderLabel(device: "owner-pc"), "진원 · PC")
        XCTAssertEqual(Strings.senderLabel(device: "jungin-iphone-1b89e3"), "쩡이🍎 · 아이폰")
        XCTAssertEqual(Strings.senderLabel(device: "dad"), "dad")
        XCTAssertEqual(Strings.senderLabel(device: "bot-gongmyoung"), "공명✴️")
        XCTAssertEqual(Strings.senderLabel(device: "dungae-bot"), "등애✳️")
    }

    func testPreviewLineDropsMarkdownNoise() {
        XCTAssertEqual(Strings.previewLine(name: "공명", body: "## 결과\n| 방 | 모드 |\n**두 개**입니다 `room_status`"),
                       "공명: 결과 방 | 모드 | 두 개입니다 room_status")
    }

    func testMessageTimeAndDayLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = Date(timeIntervalSince1970: 1_792_306_680)  // 2026-10-18 15:58 KST(토)
        XCTAssertEqual(Strings.dayLabel(now, now: now, calendar: calendar), "오늘")
        XCTAssertEqual(Strings.dayLabel(now.addingTimeInterval(-86_400), now: now, calendar: calendar), "어제")
        XCTAssertTrue(Strings.dayLabel(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar).hasSuffix("요일"))
        XCTAssertTrue(Strings.dayLabel(now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar).contains("년"))
        let time = Strings.messageTime(now)
        XCTAssertTrue(time.hasPrefix("오전") || time.hasPrefix("오후"), time)
    }

    func testListHeaderWordmarkAndTagline() {
        XCTAssertEqual(Strings.wordmark, "hande")
        XCTAssertEqual(Strings.campfireSubtitle, "오늘 밤, 모닥불에 한데 모여")
    }

    /// 워드마크 윤곽: 파서가 끝까지 읽고(h1·a2·n1·d2·e2 = 닫힌 윤곽 8개), 모든 점이 선언한 칸 안에 있다.
    func testWordmarkArtParsesWithinItsBox() throws {
        let commands = try XCTUnwrap(SVGPathData.parse(HandeWordmarkArt.d))
        XCTAssertEqual(commands.filter { $0 == .close }.count, 8)
        var points: [SVGPathData.Point] = []
        for command in commands {
            switch command {
            case .move(let a), .line(let a): points.append(a)
            case .cubic(let c1, let c2, let e): points += [c1, c2, e]
            case .quad(let q, let e): points += [q, e]
            case .close: break
            }
        }
        XCTAssertFalse(points.isEmpty)
        for p in points {
            XCTAssertTrue((0...HandeWordmarkArt.width).contains(p.x) && (0...HandeWordmarkArt.height).contains(p.y), "\(p)")
        }
    }

    /// #422 · 결정 2026-10-19 ③: 닉네임·방 이름 = Matrix 와 동일(웹 strings.test.mjs 와 같은 벡터).
    func testNamesMatchMatrix() {
        XCTAssertEqual(Strings.agentNames["gongmyoung"], "공명✴️")
        XCTAssertEqual(Strings.agentNames.count, 12)
        XCTAssertEqual(Strings.roomLabel("family"), "가족")
        XCTAssertEqual(Strings.roomLabel("family-acc"), "공명✴️")
        XCTAssertEqual(Strings.roomLabel("dungae"), "등애✳️")
        XCTAssertEqual(Strings.roomLabel("test-rs2"), "test-rs2")
    }

    func testServiceBotNames() {
        XCTAssertEqual(Strings.senderLabel(device: "card-bot"), "💳 카드 알림")
        XCTAssertEqual(Strings.roomLabel("family-card"), "💳 가족 카드 알림")
        XCTAssertEqual(Strings.senderLabel(device: "fleet-bot"), "🔔 플릿 알림")
        XCTAssertEqual(Strings.roomLabel("fleet-alerts"), "🔔 플릿 알림")
        XCTAssertEqual(Strings.senderLabel(device: "bunjang-bot"), "⚡ 번개장터 알림")
        XCTAssertEqual(Strings.roomLabel("bunjang-alerts"), "⚡ 번개장터 알림")
        XCTAssertEqual(Strings.senderLabel(device: "insta-bot"), "📷 인스타 알림")
        XCTAssertEqual(Strings.roomLabel("insta-news"), "📷 인스타 새 글")
    }
}
