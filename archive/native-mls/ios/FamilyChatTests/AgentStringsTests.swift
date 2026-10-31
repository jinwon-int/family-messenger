import XCTest
import FamilyMLSCore
@testable import FamilyChat

/// #405 P1: 승인 버튼이 보내는 글은 봇이 알아듣는 형식이어야 하고(native-mls-bot `parse_approval_reply`), 이름 조사는 받침을 따른다.
final class AgentStringsTests: XCTestCase {
    func testApprovalButtonsSendTheBotsReplyFormat() {
        XCTAssertEqual(Strings.approvalReply(3, allow: true), "승인 3")
        XCTAssertEqual(Strings.approvalReply(12, allow: false), "거절 12")
    }

    /// agent-choices-v1(#620 · 복수 #624): 보내기 = 손으로 치는 답과 같은 `2` / `1, 3` · 답한 줄 · 접근성 라벨.
    func testChoiceCardStrings() {
        XCTAssertEqual(AgentChoices.compose([2]), "2")
        XCTAssertEqual(AgentChoices.compose([3, 1]), "1, 3")
        XCTAssertEqual(AgentChoices.reply(AgentChoices.compose([3, 1]), count: 3), [1, 3], "보낸 글이 다시 answered 로 읽혀야 한다")
        XCTAssertEqual(Strings.choiceAnswered([1], labels: ["병합"]), "✓ 1번 선택 — 병합")
        XCTAssertEqual(Strings.choiceAnswered([1, 3], labels: ["병합", "롤백"]), "✓ 1, 3번 선택 — 병합 · 롤백")
        XCTAssertEqual(Strings.choiceRowA11y(2, label: "보류", recommended: false), "2번: 보류")
        XCTAssertEqual(Strings.choiceRowA11y(1, label: "병합", recommended: true), "1번: 병합, 권장")
        XCTAssertEqual(Strings.choiceRowA11yValue(true), "체크됨")
        XCTAssertEqual(Strings.choiceRowA11yValue(false), "체크 안 됨")
        XCTAssertEqual(Strings.choiceSendA11y([2]), "2번 보내기")
        XCTAssertEqual(Strings.choiceSendA11y([3, 1]), "1, 3번 보내기")
        XCTAssertEqual(Strings.choiceSendA11y([]), "보내기")
    }

    func testSubjectParticleFollowsTheFinalConsonant() {
        XCTAssertEqual(Strings.approvalTitle("공명"), "공명이 허락을 구합니다")
        XCTAssertEqual(Strings.approvalTitle("루나"), "루나가 허락을 구합니다")
        XCTAssertEqual(Strings.subjectParticle("newnode"), "이(가)")
    }

    /// #601: 답 없음 표시는 앱 추정이다 — 작업 중("생각하는 중")이라고 단정하지 않고 기다림만 말한다.
    func testAwaitingReplyDoesNotClaimTheAgentIsWorking() {
        XCTAssertEqual(Strings.agentAwaitingReply("노숙"), "노숙의 답 기다리는 중")
        XCTAssertEqual(Strings.agentAwaitingReply("공명✴️"), "공명✴️의 답 기다리는 중")
        XCTAssertFalse(Strings.agentAwaitingReply("공명").contains("생각"))
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
        XCTAssertEqual(Strings.previewLine(name: "", body: "**두 개**입니다"), "두 개입니다", "1:1 방 — 이름 접두 없음")
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

    /// 방 목록 카드 오른쪽의 마지막 말 시각(오너 2026-10-30).
    func testRelativeTimeForRoomList() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = Date(timeIntervalSince1970: 1_792_306_680)  // 2026-10-18 15:58 KST
        func rel(_ ago: TimeInterval) -> String { Strings.relativeTime(now.addingTimeInterval(-ago), now: now, calendar: calendar) }
        XCTAssertEqual(rel(0), "방금")
        XCTAssertEqual(rel(59), "방금")
        XCTAssertEqual(rel(-120), "방금")  // 시계 어긋남(미래)
        XCTAssertEqual(rel(60), "1분 전")
        XCTAssertEqual(rel(59 * 60 + 59), "59분 전")
        XCTAssertEqual(rel(3_600), "1시간 전")
        XCTAssertEqual(rel(23 * 3_600 + 59 * 60), "23시간 전")
        XCTAssertEqual(rel(86_400), "1일 전")
        XCTAssertEqual(rel(6 * 86_400), "6일 전")
        let older = rel(10 * 86_400)
        XCTAssertTrue(older.hasSuffix("일") && older.contains("월") && !older.contains("년"), older)
        XCTAssertTrue(rel(400 * 86_400).contains("년"))
    }

    func testListHeaderWordmarkAndTagline() {
        XCTAssertEqual(Strings.wordmark, "hande")
        XCTAssertEqual(Strings.campfireSubtitle, "오늘 밤, 모닥불에 한데 모여")
    }

    /// 디자인 1차 용어 적용표(오너 「전부 적용」): 자리 · 불지기 · 불 피우기 · 타닥타닥 · 불씨가 튀었어요 · 불이 꺼진 자리. 동작어(보내기)는 그대로.
    func testCampfireTerminology() {
        XCTAssertEqual(Strings.roomsTitle, "자리")
        XCTAssertEqual(Strings.agentBadge, "불지기")
        XCTAssertEqual(Strings.createTitle, "불 피우기")
        XCTAssertEqual(Strings.createSheetTitle, "새 자리 — 불 피우기")
        XCTAssertEqual(Strings.pushHiddenPreviewPlaceholder, "불씨가 튀었어요")
        XCTAssertEqual(Strings.roomClosedByOperator, "불이 꺼진 자리 · 운영자가 닫음")
        XCTAssertEqual(Strings.haltedRoomsTitle, "불이 꺼진 자리")
        XCTAssertEqual(Strings.sendButton, "보내기")
        XCTAssertTrue(Strings.noRooms.contains("자리(대화방)"), "첫 노출 보조 설명 1회")
    }

    /// 「정인이 타닥타닥…」: 웹 한데 strings.js `subjectParticle` 과 같은 벡터 — 꼬리 이모지를 건너뛰고 받침 판정, 영문은 「이」. 1:1 방은 이름 없이.
    func testTypingLabelIsCrackling() {
        XCTAssertEqual(Strings.typing, "타닥타닥…")
        XCTAssertEqual(Strings.typingLabel([]), "타닥타닥…")
        XCTAssertEqual(Strings.typingLabel(["정인"]), "정인이 타닥타닥…")
        XCTAssertEqual(Strings.typingLabel(["루나"]), "루나가 타닥타닥…")
        XCTAssertEqual(Strings.typingLabel(["쩡이🍎"]), "쩡이🍎가 타닥타닥…")
        XCTAssertEqual(Strings.typingLabel(["공명✴️"]), "공명✴️이 타닥타닥…")
        XCTAssertEqual(Strings.typingLabel(["쩡이🍎", "진원"]), "쩡이🍎, 진원이 타닥타닥…")
        XCTAssertEqual(Strings.typingLabel(["jinon86"]), "jinon86이 타닥타닥…")
    }

    /// 오늘의 불 세기는 말로만(숫자 없음).
    func testFireLevelLabel() {
        XCTAssertEqual(Strings.fireLevelLabel(1), "오늘의 불 세기 조용함")
        XCTAssertEqual(Strings.fireLevelLabel(2), "오늘의 불 세기 보통")
        XCTAssertEqual(Strings.fireLevelLabel(3), "오늘의 불 세기 활발")
        XCTAssertEqual(Strings.seatAgents(["공명✴️"]), "불지기 공명✴️")
        XCTAssertEqual(Strings.seatPeople(3), "가족 3")
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
