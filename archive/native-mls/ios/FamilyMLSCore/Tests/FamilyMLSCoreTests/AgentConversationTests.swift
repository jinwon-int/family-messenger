import XCTest
@testable import FamilyMLSCore

final class AgentMarkdownTests: XCTestCase {
    func testBotStatusReplyBecomesParagraphHeadingTableAndList() {
        let body = """
        방 상태를 확인했는데, **`test-rs`라는 방이 없습니다.**

        **확인한 내용** (`room_status`)
        | 방 | 모드 | joined |
        |---|---|:---:|
        | `family` | silent | ✅ |
        | `family-acc` | agent | ✅ |

        - 봇이 알고 있는 방은 이 두 개뿐입니다.
        - `family-acc`를 말씀하신 것일 수도 있지만
          짐작으로 바꾸지는 않았습니다.

        1. **`family-acc`를 silent로 바꾸기** — 권장
        2. 그대로 두기
        """
        let blocks = AgentMarkdown.parse(body)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0], .paragraph("방 상태를 확인했는데, **`test-rs`라는 방이 없습니다.**"))
        XCTAssertEqual(blocks[1], .paragraph("**확인한 내용** (`room_status`)"))
        XCTAssertEqual(blocks[2], .table(header: ["방", "모드", "joined"],
                                         rows: [["`family`", "silent", "✅"], ["`family-acc`", "agent", "✅"]]))
        guard case .list(let bullets) = blocks[3] else { return XCTFail("\(blocks[3])") }
        XCTAssertEqual(bullets.count, 2)
        XCTAssertNil(bullets[0].marker)
        XCTAssertEqual(bullets[1].text, "`family-acc`를 말씀하신 것일 수도 있지만\n짐작으로 바꾸지는 않았습니다.")
        guard case .list(let numbered) = blocks[4] else { return XCTFail("\(blocks[4])") }
        XCTAssertEqual(numbered.map(\.marker), ["1.", "2."])
    }

    func testTableWithoutTheParagraphBreakStillSplits() {
        let blocks = AgentMarkdown.parse("요약\n| a | b |\n|---|---|\n| 1 | 2 |\n끝")
        XCTAssertEqual(blocks, [.paragraph("요약"), .table(header: ["a", "b"], rows: [["1", "2"]]), .paragraph("끝")])
    }

    func testRaggedAndOversizedTablesAreNormalized() {
        let long = (0..<70).map { "| r\($0) |" }.joined(separator: "\n")
        let blocks = AgentMarkdown.parse("| a | b |\n|---|---|\n| only |\n| x | y | z |\n" + long)
        guard case .table(let header, let rows) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(header, ["a", "b"])
        XCTAssertEqual(rows[0], ["only", ""])
        XCTAssertEqual(rows[1], ["x", "y"])
        XCTAssertEqual(rows.count, AgentMarkdown.maxRows + 1)
        XCTAssertEqual(rows.last, ["…", ""])
    }

    func testCodeHeadingQuoteRule() {
        let blocks = AgentMarkdown.parse("# 제목\n## 소제목\n```sh\nls -la\n| not | a table |\n```\n> 인용\n> 둘째 줄\n---\n#해시태그")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "제목"), .heading(level: 2, text: "소제목"),
            .code("ls -la\n| not | a table |"), .quote("인용\n둘째 줄"), .rule, .paragraph("#해시태그"),
        ])
    }

    func testUnclosedFenceAndPlainTextAreSafe() {
        XCTAssertEqual(AgentMarkdown.parse("```\nopen"), [.code("open")])
        XCTAssertEqual(AgentMarkdown.parse("그냥 한 줄"), [.paragraph("그냥 한 줄")])
        XCTAssertEqual(AgentMarkdown.parse(""), [])
        XCTAssertEqual(AgentMarkdown.parse("a | b 는 표가 아니다"), [.paragraph("a | b 는 표가 아니다")])
        XCTAssertEqual(AgentMarkdown.parse("**굵게**만"), [.paragraph("**굵게**만")])
    }
}

final class AgentConversationTests: XCTestCase {
    let roster = AgentRoster(setting: " bot , ")
    let me: DeviceID = "owner-iphone-27a879"
    let bot: DeviceID = "bot-gongmyoung"
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func rec(_ seq: Int64, _ device: DeviceID, _ body: String, kind: MessageRecord.Kind = .text, at offset: TimeInterval = 0) -> MessageRecord {
        MessageRecord(room: "family-acc", seq: seq, senderDevice: device, clientId: "c\(seq)", kind: kind, body: body,
                      attachment: nil, receivedAt: t0.addingTimeInterval(offset), decryptedBy: .app)
    }

    func testRosterAndNames() {
        XCTAssertEqual(roster.actors, ["bot"])
        XCTAssertTrue(roster.isAgent(rec(1, bot, "hi")))
        XCTAssertFalse(roster.isAgent(rec(1, me, "hi")))
        let names = ["gongmyoung": "공명", "owner": "나"]
        XCTAssertEqual(AgentRoster.displayName(device: bot, names: names), "공명")
        XCTAssertEqual(AgentRoster.displayName(device: "bot-newnode", names: names), "newnode")
        XCTAssertEqual(AgentRoster.displayName(device: me, names: names), "나")
        XCTAssertEqual(AgentRoster.displayName(device: "jungin-iphone-1b89e3", names: names), "jungin")
    }

    func testApprovalParsersMatchTheBotsWording() {
        let req = AgentApproval.request(in: "⚠️ 승인 필요 #12: 방 명령 room_create · mode=silent · room=test-rs\n답장: 「승인 12」 또는 「거절 12」 (owner 만)")
        XCTAssertEqual(req, AgentApproval.Request(number: 12, summary: "방 명령 room_create · mode=silent · room=test-rs"))
        XCTAssertNil(AgentApproval.request(in: "승인 필요한 일은 없습니다"))
        XCTAssertEqual(AgentApproval.resolution(in: "승인 #1: 허용했습니다.")?.allowed, true)
        XCTAssertEqual(AgentApproval.resolution(in: "승인 #3: 거절했습니다.")?.number, 3)
        XCTAssertNil(AgentApproval.resolution(in: "승인 #x: 허용했습니다."))
        XCTAssertEqual(AgentApproval.reply(in: " 승인 1 ")?.allowed, true)
        XCTAssertEqual(AgentApproval.reply(in: "거절 #2")?.number, 2)
        XCTAssertEqual(AgentApproval.reply(in: "approve 4")?.allowed, true)
        XCTAssertNil(AgentApproval.reply(in: "승인 해줘"))
    }

    func testApprovalLifecycle() {
        let records = [
            rec(1, me, "test-rs 만들어줘"),
            rec(2, bot, "⚠️ 승인 필요 #1: 방 명령 room_create\n답장: …"),
            rec(3, bot, "⚠️ 승인 필요 #2: 방 명령 room_invite\n답장: …"),
            rec(4, me, "승인 1"),
            rec(5, bot, "승인 #1: 허용했습니다."),
            rec(6, me, "거절 2"),
        ]
        var states = AgentApproval.states(records, roster: roster)
        XCTAssertEqual(states[2], .allowed)
        XCTAssertEqual(states[3], .answered(allowed: false))
        states = AgentApproval.states(records + [rec(7, bot, "승인 #2: 거절했습니다.")], roster: roster)
        XCTAssertEqual(states[3], .denied)
    }

    func testTurnEndOrReusedNumberClosesOpenRequests() {
        let open = [rec(1, bot, "⚠️ 승인 필요 #1: a")]
        XCTAssertEqual(AgentApproval.states(open, roster: roster)[1], .open)
        let restarted = open + [rec(2, bot, "⚠️ 요청(#9)을 끝까지 확인하지 못했습니다(restart). 다시 말씀해 주세요")]
        XCTAssertEqual(AgentApproval.states(restarted, roster: roster)[1], .closed)
        let reused = open + [rec(2, bot, "⚠️ 승인 필요 #1: b")]
        let states = AgentApproval.states(reused, roster: roster)
        XCTAssertEqual(states[1], .closed)
        XCTAssertEqual(states[2], .open)
        // 에이전트가 아닌 기기가 같은 글을 써도 요청이 아니다.
        XCTAssertNil(AgentApproval.states([rec(1, me, "⚠️ 승인 필요 #1: 가짜")], roster: roster)[1])
    }

    func testLastSentSkipsApprovalRepliesAndCountsReplies() {
        let records = [
            rec(1, me, "방 상태 알려줘"),
            rec(2, bot, "두 개입니다"),
            rec(3, me, "test-rs 만들어줘"),
            rec(4, bot, "⚠️ 승인 필요 #1: x"),
            rec(5, me, "승인 1"),
            rec(6, bot, "승인 #1: 허용했습니다."),
            rec(7, "owner-pc", "사진", kind: .attachment),
            rec(8, bot, "없음", kind: .undecryptable),
        ]
        let last = LastSent.find(records, myDevice: me)
        XCTAssertEqual(last?.record.seq, 7, "the photo from my PC (same actor, other device) is my last word too")
        XCTAssertEqual(last?.repliesAfter, 0, "undecryptable rows don't count")
        let beforePhoto = LastSent.find(Array(records.prefix(6)), myDevice: me)
        XCTAssertEqual(beforePhoto?.record.seq, 3)
        XCTAssertEqual(beforePhoto?.repliesAfter, 2, "bot request, bot resolution — my own approval reply doesn't count")
        XCTAssertNil(LastSent.find([rec(1, bot, "hi")], myDevice: me))
        XCTAssertNil(LastSent.find(records, myDevice: ""))
    }

    func testThinkingOnlyAfterMyTextInAnAgentRoomWithinTheWindow() {
        let base = [rec(1, me, "안녕"), rec(2, bot, "안녕하세요")]
        XCTAssertNil(AgentThinking.agent(base, roster: roster, myDevice: me, now: t0))
        let asked = base + [rec(3, me, "방 상태 알려줘", at: 10)]
        XCTAssertEqual(AgentThinking.agent(asked, roster: roster, myDevice: me, now: t0.addingTimeInterval(20)), bot)
        XCTAssertNil(AgentThinking.agent(asked, roster: roster, myDevice: me, now: t0.addingTimeInterval(10 + AgentThinking.window)))
        // 승인 답장 뒤에도 에이전트는 이어서 일한다.
        let approved = base + [rec(3, bot, "⚠️ 승인 필요 #1: x"), rec(4, me, "승인 1", at: 5)]
        XCTAssertEqual(AgentThinking.agent(approved, roster: roster, myDevice: me, now: t0.addingTimeInterval(6)), bot)
        // 사람만 있는 방, 첨부, 다른 사람이 마지막.
        XCTAssertNil(AgentThinking.agent([rec(1, "jungin-iphone-1", "hi"), rec(2, me, "응")], roster: roster, myDevice: me, now: t0))
        XCTAssertNil(AgentThinking.agent(base + [rec(3, me, "photo", kind: .attachment)], roster: roster, myDevice: me, now: t0))
        XCTAssertNil(AgentThinking.agent(base + [rec(3, "jungin-iphone-1", "저녁?")], roster: roster, myDevice: me, now: t0))
        // 같은 사람이 PC 에서 물어도 iPhone 에 "생각하는 중"이 보인다(다른 기기 = 같은 나).
        XCTAssertEqual(AgentThinking.agent(base + [rec(3, "owner-pc", "pc")], roster: roster, myDevice: me, now: t0), bot)
    }

    func testMineFollowsTheActorAcrossDevices() {
        XCTAssertTrue(rec(1, "owner-pc", "pc").isMine(device: me))
        XCTAssertTrue(rec(1, me, "x").isMine(device: me))
        XCTAssertFalse(rec(1, "jungin-iphone-1", "x").isMine(device: me))
        XCTAssertFalse(rec(1, bot, "x").isMine(device: me))
        XCTAssertFalse(rec(1, me, "x").isMine(device: ""))
        XCTAssertEqual(MessageRecord.actor(of: "owner-web-87576b"), "owner")
        XCTAssertEqual(MessageRecord.actor(of: "nodash"), "nodash")
    }
}

final class RoomGlanceTests: XCTestCase {
    let roster = AgentRoster(actors: ["bot"])

    func rec(_ seq: Int64, _ device: DeviceID, _ body: String, kind: MessageRecord.Kind = .text) -> MessageRecord {
        MessageRecord(room: "family", seq: seq, senderDevice: device, clientId: "c\(seq)", kind: kind, body: body,
                      attachment: nil, receivedAt: Date(timeIntervalSince1970: 0), decryptedBy: .app)
    }

    func testSeatsAndPreview() {
        let glance = RoomGlance.make([
            rec(1, "owner-iphone-1", "안녕"),
            rec(2, "bot-gongmyoung", "안녕하세요"),
            rec(3, "jungin-iphone-2", "저녁 뭐 먹어?"),
            rec(4, "owner-pc", "사진", kind: .attachment),
            rec(5, "x-1", "열 수 없음", kind: .undecryptable),
        ], roster: roster)
        XCTAssertEqual(glance.people, ["owner", "jungin"], "same actor on two devices is one seat")
        XCTAssertEqual(glance.agents, ["bot-gongmyoung"])
        XCTAssertTrue(glance.hasAgent)
        XCTAssertEqual(glance.last?.seq, 4, "undecryptable rows are not previewed")
    }

    func testEmptyRoom() {
        let glance = RoomGlance.make([], roster: roster)
        XCTAssertNil(glance.last)
        XCTAssertFalse(glance.hasAgent)
    }

    func testDeviceKind() {
        XCTAssertEqual(DeviceLabel.kind("owner-iphone-27a879"), "iphone")
        XCTAssertEqual(DeviceLabel.kind("owner-PC"), "pc")
        XCTAssertNil(DeviceLabel.kind("owner"))
    }
}

final class ConversationKeysTests: XCTestCase {
    func testEnterSendsShiftEnterAndSoftKeyboardKeepTheNewline() {
        XCTAssertEqual(ComposerKeys.decide(old: "안녕", new: "안녕\n", hardwareKeyboard: true, shift: false), .send("안녕"))
        XCTAssertEqual(ComposerKeys.decide(old: "안녕", new: "안녕\n", hardwareKeyboard: true, shift: true), .keep)
        XCTAssertEqual(ComposerKeys.decide(old: "안녕", new: "안녕\n", hardwareKeyboard: false, shift: false), .keep)
        // 가운데에서 Enter 도 전송(웹과 같음) — 보내는 글은 줄바꿈이 들어가기 전 글.
        XCTAssertEqual(ComposerKeys.decide(old: "ab", new: "a\nb", hardwareKeyboard: true, shift: false), .send("ab"))
        XCTAssertEqual(ComposerKeys.decide(old: "", new: "\n", hardwareKeyboard: true, shift: false), .revert(""))
        XCTAssertEqual(ComposerKeys.decide(old: "  ", new: "  \n", hardwareKeyboard: true, shift: false), .revert("  "))
        // 줄바꿈이 아닌 입력, 붙여넣기(여러 글자), 지우기는 그대로.
        XCTAssertEqual(ComposerKeys.decide(old: "ab", new: "abc", hardwareKeyboard: true, shift: false), .keep)
        XCTAssertEqual(ComposerKeys.decide(old: "ab", new: "ab\n\n", hardwareKeyboard: true, shift: false), .keep)
        XCTAssertEqual(ComposerKeys.decide(old: "ab", new: "a", hardwareKeyboard: true, shift: false), .keep)
    }

    func room(_ id: RoomID, _ order: Int) -> RoomRecord {
        RoomRecord(room: id, epoch: 0, revision: 0, haltedReason: nil, displayOrder: order)
    }

    func testRoomOrderOverlayAndMoves() {
        let rooms = [room("family", 0), room("family-acc", 1), room("test", 2)]
        XCTAssertEqual(RoomOrder.apply(rooms, saved: []).map(\.room), ["family", "family-acc", "test"])
        XCTAssertEqual(RoomOrder.apply(rooms, saved: ["family-acc", "gone", "family-acc"]).map(\.room), ["family-acc", "family", "test"])
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(RoomOrder.move(ids, from: [3], to: 0), ["d", "a", "b", "c"])
        XCTAssertEqual(RoomOrder.move(ids, from: [0], to: 4), ["b", "c", "d", "a"])
        XCTAssertEqual(RoomOrder.move(ids, from: [0], to: 2), ["b", "a", "c", "d"])
        XCTAssertEqual(RoomOrder.move(ids, from: [1, 2], to: 0), ["b", "c", "a", "d"])
        XCTAssertEqual(RoomOrder.neighbor(of: "b", in: ids, step: 1), "c")
        XCTAssertEqual(RoomOrder.neighbor(of: "a", in: ids, step: -1), nil)
        XCTAssertEqual(RoomOrder.neighbor(of: "zz", in: ids, step: 1), "a")
    }

    /// #549: ▲▼ 한 칸 이동·「맨 위로 고정」 — 끝·없는 방·0 이동은 nil(저장하지 않음).
    func testRoomOrderStepAndMoveToTop() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(RoomOrder.step(ids, room: "b", by: -1), ["b", "a", "c", "d"])
        XCTAssertEqual(RoomOrder.step(ids, room: "b", by: 1), ["a", "c", "b", "d"])
        XCTAssertNil(RoomOrder.step(ids, room: "a", by: -1))
        XCTAssertNil(RoomOrder.step(ids, room: "d", by: 1))
        XCTAssertNil(RoomOrder.step(ids, room: "zz", by: 1))
        XCTAssertNil(RoomOrder.step(ids, room: "b", by: 0))
        XCTAssertTrue(RoomOrder.canStep(ids, room: "a", by: 1))
        XCTAssertFalse(RoomOrder.canStep(ids, room: "a", by: -1))
        XCTAssertFalse(RoomOrder.canStep(ids, room: "d", by: 1))
        XCTAssertEqual(RoomOrder.moveToTop(ids, room: "c"), ["c", "a", "b", "d"])
        XCTAssertEqual(RoomOrder.moveToTop(ids, room: "d"), ["d", "a", "b", "c"])
        XCTAssertNil(RoomOrder.moveToTop(ids, room: "a"))
        XCTAssertNil(RoomOrder.moveToTop(ids, room: "zz"))
        XCTAssertNil(RoomOrder.moveToTop([], room: "a"))
        // 화면 순서에서 한 칸 옮긴 결과를 저장하면 apply 가 그대로 돌려준다(저장 순서에 없던 방도 포함되므로 유실 없음).
        let rooms = [room("family", 0), room("family-acc", 1), room("test", 2)]
        let visible = RoomOrder.apply(rooms, saved: []).map(\.room)
        let saved = RoomOrder.step(visible, room: "test", by: -1)!
        XCTAssertEqual(RoomOrder.apply(rooms, saved: saved).map(\.room), ["family", "test", "family-acc"])
    }

    func testUnreadIsLocalAndIgnoresMyOwnMessages() {
        func rec(_ seq: Int64, _ device: DeviceID) -> MessageRecord {
            MessageRecord(room: "r", seq: seq, senderDevice: device, clientId: "c", kind: .text, body: "x",
                          attachment: nil, receivedAt: Date(timeIntervalSince1970: 0), decryptedBy: .app)
        }
        XCTAssertTrue(Unread.isUnread(last: rec(5, "bot-g"), myDevice: "owner-i", readSeq: 4))
        XCTAssertTrue(Unread.isUnread(last: rec(5, "bot-g"), myDevice: "owner-i", readSeq: nil))
        XCTAssertFalse(Unread.isUnread(last: rec(5, "bot-g"), myDevice: "owner-i", readSeq: 5))
        XCTAssertFalse(Unread.isUnread(last: rec(6, "owner-i"), myDevice: "owner-i", readSeq: 1))
        XCTAssertFalse(Unread.isUnread(last: rec(7, "owner-pc"), myDevice: "owner-i", readSeq: 1), "my own word from another device is not unread")
        XCTAssertTrue(Unread.isUnread(last: rec(7, "jungin-iphone-1"), myDevice: "owner-i", readSeq: 1))
        XCTAssertFalse(Unread.isUnread(last: nil, myDevice: "owner-i", readSeq: nil))
    }
}

final class TimelineStampsTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }()

    /// 2026-10-18 15:58:00 KST = 1792306680
    let base: TimeInterval = 1_792_306_680

    func rec(_ seq: Int64, _ device: DeviceID, at offset: TimeInterval) -> MessageRecord {
        MessageRecord(room: "r", seq: seq, senderDevice: device, clientId: "c", kind: .text, body: "x",
                      attachment: nil, receivedAt: Date(timeIntervalSince1970: base + offset), decryptedBy: .app)
    }

    func testTimeOnLastOfSameSenderSameMinuteRun() {
        let stamps = TimelineStamps.compute([
            rec(1, "me", at: 0), rec(2, "me", at: 20), rec(3, "bot", at: 30), rec(4, "bot", at: 70), rec(5, "me", at: 75),
        ], calendar: calendar)
        XCTAssertEqual(stamps[1]?.showTime, false, "me, me in the same minute → only the second shows")
        XCTAssertEqual(stamps[2]?.showTime, true)
        XCTAssertEqual(stamps[3]?.showTime, true, "15:58:30 and 15:59:10 are different minutes")
        XCTAssertEqual(stamps[4]?.showTime, true)
        XCTAssertEqual(stamps[5]?.showTime, true, "the last row always shows")
    }

    func testDayDividerOnFirstRowAndWhenTheDateChanges() {
        let stamps = TimelineStamps.compute([
            rec(1, "me", at: 0), rec(2, "me", at: 60),
            rec(3, "me", at: 8 * 3600 + 3 * 60),   // 다음날 00:01 KST
        ], calendar: calendar)
        XCTAssertNotNil(stamps[1]?.dayStart)
        XCTAssertNil(stamps[2]?.dayStart)
        XCTAssertEqual(stamps[3]?.dayStart, calendar.startOfDay(for: Date(timeIntervalSince1970: base + 8 * 3600 + 3 * 60)))
        XCTAssertNotEqual(stamps[1]?.dayStart, stamps[3]?.dayStart)
        XCTAssertTrue(TimelineStamps.compute([], calendar: calendar).isEmpty)
    }
}
