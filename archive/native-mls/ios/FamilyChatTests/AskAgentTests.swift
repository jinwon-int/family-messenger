// Siri·단축어 「공명에게 묻기」·「공명에게 기록 맡기기」의 규칙(AgentAsk) — 금지어 · `[Siri·…]` 머리글 · 길이 · 기다리기 흐름(가짜 송신·수신).
// AppIntents 파일과 같은 앱 타깃이라 macOS(ios-build)에서만 돈다. AppModel 쪽(seq·답 찾기·기다리기 루프)은 OutgoingTests(Linux 스모크도 돈다).
import XCTest
@testable import FamilyChat

@MainActor
final class AskAgentTests: XCTestCase {
    /// 가짜 송신·수신이 받은 것을 적어 둔다.
    private final class Recorder {
        var sent: [String] = []
        var waitedAfter: [Int64] = []
        var waitedTimeout: [TimeInterval] = []
    }

    private func run(_ kind: AgentAsk.Kind, _ text: String, receipt: AppModel.ShortcutReceipt,
                     reply: String?, _ recorder: Recorder) async -> AgentAsk.Outcome {
        await AgentAsk.run(kind, text: text, timeout: 20,
                           send: { recorder.sent.append($0); return receipt },
                           awaitReply: { after, timeout in
                               recorder.waitedAfter.append(after)
                               recorder.waitedTimeout.append(timeout)
                               return reply
                           })
    }

    // MARK: - 금지어

    func testRiskyKoreanAndEnglishWordsAreRefused() {
        let risky = [
            "PR 123 머지하라고 해",
            "어제 만든 빌드 배포해 줘",
            "이 PR 승인해",
            "엄마한테 사진 보내 줘",
            "메일 지워 줘",
            "please merge PR 12",
            "merge해줘",
            "Deploying the relay now",
            "approved?",
            "log out of the account",
            "Cancelled orders",
        ]
        for text in risky {
            XCTAssertFalse(AgentAsk.riskyWords(in: text).isEmpty, "should refuse: \(text)")
            XCTAssertEqual(AgentAsk.refusal(.question, text), Strings.siriRisky, text)
            XCTAssertEqual(AgentAsk.refusal(.note, text), Strings.siriRisky, text)
        }
    }

    func testOrdinaryQuestionsPass() {
        let fine = [
            "오늘 날씨 어때?",
            "내일 일정 알려줘",
            "열린 PR 리뷰 상태 알려줘",
            "걸어서 가는 길",
            "emergency kit 목록 정리해 줘",
            "postgres 버전이 뭐야",
            "What is on my reading list?",
        ]
        for text in fine {
            XCTAssertEqual(AgentAsk.riskyWords(in: text), [], "false positive: \(text)")
            XCTAssertNil(AgentAsk.refusal(.question, text), text)
        }
    }

    func testRiskyWordsAreListedOnce() {
        XCTAssertEqual(AgentAsk.riskyWords(in: "머지하고 배포, merge merged deploy"), ["머지", "배포", "merge", "deploy"])
    }

    // MARK: - 머리글 · 길이

    func testHeaderPrefixes() {
        XCTAssertEqual(AgentAsk.compose(.question, "  오늘 할 일 알려줘 \n"), "[Siri·질문] 오늘 할 일 알려줘")
        XCTAssertEqual(AgentAsk.compose(.note, "우유 사기"), "[Siri·기록] 우유 사기")
    }

    func testEmptyAndTooLongAreRefused() {
        XCTAssertEqual(AgentAsk.refusal(.question, " \n "), Strings.shortcutEmpty)
        XCTAssertNil(AgentAsk.refusal(.question, String(repeating: "가", count: 500)))
        XCTAssertEqual(AgentAsk.refusal(.question, String(repeating: "가", count: 501)), Strings.siriTooLong(500))
        XCTAssertNil(AgentAsk.refusal(.note, String(repeating: "가", count: 1000)))
        XCTAssertEqual(AgentAsk.refusal(.note, String(repeating: "가", count: 1001)), Strings.siriTooLong(1000))
    }

    func testSnippetTruncatesLongReplies() {
        XCTAssertEqual(AgentAsk.snippet("  짧은 답 \n"), "짧은 답")
        let long = String(repeating: "나", count: AgentAsk.snippetLimit + 5)
        XCTAssertEqual(AgentAsk.snippet(long), String(repeating: "나", count: AgentAsk.snippetLimit) + Strings.siriMoreInApp)
    }

    // MARK: - 흐름(가짜 송신·수신)

    func testQuestionTimeoutReturnsWaitingDialogWithoutResending() async {
        let recorder = Recorder()
        let outcome = await run(.question, " 오늘 할 일 알려줘 ", receipt: AppModel.ShortcutReceipt(result: .sent, seq: 41), reply: nil, recorder)
        XCTAssertEqual(outcome, .waiting)
        XCTAssertEqual(recorder.sent, ["[Siri·질문] 오늘 할 일 알려줘"], "sent once, with the header")
        XCTAssertEqual(recorder.waitedAfter, [41], "waits for a reply after my own message")
        XCTAssertEqual(recorder.waitedTimeout, [20])
        XCTAssertNil(AgentAsk.failure(outcome), "a late answer is still a success — no retry")
        XCTAssertEqual(AgentAsk.dialog(outcome, room: AgentAsk.defaultRoom), Strings.siriWaiting(AgentAsk.defaultRoom))
        XCTAssertTrue(AgentAsk.dialog(outcome, room: AgentAsk.defaultRoom).contains(Strings.roomLabel(AgentAsk.defaultRoom)))
        XCTAssertEqual(AgentAsk.value(outcome), "")
    }

    func testQuestionAnsweredInTime() async {
        let recorder = Recorder()
        let outcome = await run(.question, "오늘 할 일", receipt: AppModel.ShortcutReceipt(result: .sent, seq: 7), reply: "세 가지예요.", recorder)
        XCTAssertEqual(outcome, .answered("세 가지예요."))
        XCTAssertEqual(AgentAsk.dialog(outcome, room: "family-acc"), Strings.siriAnswered("family-acc", "세 가지예요."))
        XCTAssertEqual(AgentAsk.value(outcome), "세 가지예요.")
    }

    func testRiskyQuestionSendsNothing() async {
        let recorder = Recorder()
        let outcome = await run(.question, "PR 123 머지하라고 해", receipt: AppModel.ShortcutReceipt(result: .sent, seq: 1), reply: "x", recorder)
        XCTAssertEqual(outcome, .refused(Strings.siriRisky))
        XCTAssertEqual(recorder.sent, [], "nothing reaches the room")
        XCTAssertEqual(recorder.waitedAfter, [])
        XCTAssertEqual(AgentAsk.failure(outcome), Strings.siriRisky, "the shortcut stops with the reason")
    }

    func testQueuedQuestionDoesNotWait() async {
        let recorder = Recorder()
        let outcome = await run(.question, "오늘 할 일", receipt: AppModel.ShortcutReceipt(result: .queued), reply: "x", recorder)
        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(recorder.waitedAfter, [])
        XCTAssertEqual(AgentAsk.dialog(outcome, room: "family-acc"), Strings.shortcutQueued("family-acc"))
    }

    func testSentWithoutSeqDoesNotWait() async {
        let recorder = Recorder()
        let outcome = await run(.question, "오늘 할 일", receipt: AppModel.ShortcutReceipt(result: .sent), reply: "x", recorder)
        XCTAssertEqual(outcome, .waiting, "no seq to anchor on — the answer arrives in the room")
        XCTAssertEqual(recorder.waitedAfter, [])
    }

    func testFailedSendStopsTheShortcut() async {
        let recorder = Recorder()
        let outcome = await run(.question, "오늘 할 일", receipt: AppModel.ShortcutReceipt(result: .failed(Strings.notReady)), reply: nil, recorder)
        XCTAssertEqual(outcome, .failed(Strings.notReady))
        XCTAssertEqual(AgentAsk.failure(outcome), Strings.notReady)
    }

    func testNoteIsSentWithHeaderAndNeverWaits() async {
        let recorder = Recorder()
        let outcome = await run(.note, "우유 사기", receipt: AppModel.ShortcutReceipt(result: .sent, seq: 3), reply: "x", recorder)
        XCTAssertEqual(outcome, .noted)
        XCTAssertEqual(recorder.sent, ["[Siri·기록] 우유 사기"])
        XCTAssertEqual(recorder.waitedAfter, [], "recording does not wait for an answer")
        XCTAssertEqual(AgentAsk.dialog(outcome, room: AgentAsk.defaultRoom), Strings.siriNoted(AgentAsk.defaultRoom))
    }

    // MARK: - Intent 고정값

    func testIntentsOpenTheAppSoTheSameModelSends() {
        XCTAssertTrue(AskAgentIntent.openAppWhenRun, "single writer: the app process, not a background extension")
        XCTAssertTrue(RecordNoteIntent.openAppWhenRun)
        XCTAssertEqual(AgentAsk.defaultRoom, "family-acc")
        XCTAssertEqual(AgentAsk.replyTimeout, 20)
    }

    func testAppShortcutsCoverAskAndRecord() {
        XCTAssertEqual(HandeAppShortcuts.appShortcuts.count, 2)
    }
}
