import XCTest
@testable import FamilyMLSCore

/// 말풍선 답장(2026-11-09): 본문 앞 `> 이름: 요약` 한 줄 + 빈 줄 + 내 글. 형식 무변경 — 봇·웹은 마크다운 인용으로 읽는다.
final class ReplyQuoteTests: XCTestCase {
    func testComposeThenParseRoundTrips() {
        let body = ReplyQuote.compose(name: "엄마", original: "내일 몇 시에 와?", reply: "7시쯤!\n늦으면 연락할게")
        XCTAssertEqual(body, "> 엄마: 내일 몇 시에 와?\n\n7시쯤!\n늦으면 연락할게")
        XCTAssertEqual(ReplyQuote.parse(body), ReplyQuote.Parsed(quote: "엄마: 내일 몇 시에 와?", text: "7시쯤!\n늦으면 연락할게",
                                                                 name: "엄마", seq: nil, snippet: "내일 몇 시에 와?"))
        XCTAssertEqual(ReplyQuote.visibleText(body), "7시쯤!\n늦으면 연락할게")
    }

    /// v2(2026-11-09): 답한 글의 릴레이 seq 를 `이름 #seq` 로 — 앱은 그 글로 이동, 봇은 원문 전체를 찾는다.
    func testComposeWithSeqAndParseBack() {
        let body = ReplyQuote.compose(name: "공명✴️", seq: 1253, original: "TestFlight 업로드까지 끝났습니다.", reply: "어떻게 보여?")
        XCTAssertEqual(body, "> 공명✴️ #1253: TestFlight 업로드까지 끝났습니다.\n\n어떻게 보여?")
        let parsed = ReplyQuote.parse(body)
        XCTAssertEqual(parsed?.name, "공명✴️")
        XCTAssertEqual(parsed?.seq, 1253)
        XCTAssertEqual(parsed?.snippet, "TestFlight 업로드까지 끝났습니다.")
        XCTAssertEqual(parsed?.text, "어떻게 보여?")
        XCTAssertEqual(ReplyQuote.compose(name: "", seq: 7, original: "안녕", reply: "응"), "> #7: 안녕\n\n응")
        XCTAssertEqual(ReplyQuote.parse("> #7: 안녕\n\n응")?.seq, 7)
        XCTAssertNil(ReplyQuote.parse("> #7: 안녕\n\n응")?.name)
    }

    func testMissingOrInvalidSeqIsLeftOut() {
        XCTAssertEqual(ReplyQuote.compose(name: "엄마", seq: nil, original: "안녕", reply: "응"), "> 엄마: 안녕\n\n응", "보내는 중인 글(번호 없음)")
        XCTAssertEqual(ReplyQuote.compose(name: "엄마", seq: -3, original: "안녕", reply: "응"), "> 엄마: 안녕\n\n응", "음수 = 아직 안 보낸 글")
        XCTAssertNil(ReplyQuote.parse("> 엄마 #abc: 안녕\n\n응")?.seq)
        XCTAssertEqual(ReplyQuote.parse("> 엄마 #abc: 안녕\n\n응")?.name, "엄마 #abc", "숫자가 아니면 이름 그대로")
        XCTAssertNil(ReplyQuote.parse("> 엄마#12: 안녕\n\n응")?.seq, "`#` 앞은 띄어쓰기여야")
        XCTAssertNil(ReplyQuote.parse("> 엄마 #0: 안녕\n\n응")?.seq)
        XCTAssertNil(ReplyQuote.parse("> 엄마 #99999999999999999999: 안녕\n\n응")?.seq, "Int64 넘침")
        let noLabel = ReplyQuote.parse("> 콜론 없는 인용\n\n응")
        XCTAssertNil(noLabel?.name)
        XCTAssertEqual(noLabel?.snippet, "콜론 없는 인용")
    }

    func testEmptyNameQuotesSnippetOnly() {
        XCTAssertEqual(ReplyQuote.compose(name: "", original: "안녕", reply: "응"), "> 안녕\n\n응")
    }

    func testSnippetFlattensLinesStripsQuoteMarkersAndTruncates() {
        XCTAssertEqual(ReplyQuote.snippet(of: "첫 줄\n\n  둘째 줄  \n> 인용 줄"), "첫 줄 둘째 줄 인용 줄")
        let long = String(repeating: "가", count: ReplyQuote.snippetLimit + 10)
        let s = ReplyQuote.snippet(of: long)
        XCTAssertEqual(s.count, ReplyQuote.snippetLimit + 1, "자른 뒤 「…」 한 글자")
        XCTAssertTrue(s.hasSuffix("…"))
        XCTAssertEqual(ReplyQuote.snippet(of: String(repeating: "나", count: ReplyQuote.snippetLimit)).count, ReplyQuote.snippetLimit, "한도 안이면 그대로")
    }

    func testReplyToAReplyQuotesOnlyTheInnerText() {
        let first = ReplyQuote.compose(name: "엄마", original: "내일 몇 시에 와?", reply: "7시쯤!")
        let second = ReplyQuote.compose(name: "아빠", original: first, reply: "좋아")
        XCTAssertEqual(second, "> 아빠: 7시쯤!\n\n좋아", "인용이 겹겹이 쌓이지 않는다")
        let withSeq = ReplyQuote.compose(name: "엄마", seq: 10, original: "질문", reply: "답")
        XCTAssertEqual(ReplyQuote.compose(name: "아빠", seq: 11, original: withSeq, reply: "좋아"), "> 아빠 #11: 답\n\n좋아")
    }

    func testOrdinaryTextAndPlainQuotesAreNotReplies() {
        XCTAssertNil(ReplyQuote.parse("그냥 글"))
        XCTAssertNil(ReplyQuote.parse("> 인용만 있는 글"), "본문 없음")
        XCTAssertNil(ReplyQuote.parse("> 인용\n바로 이어진 줄"), "빈 줄 없음 — 마크다운에선 한 인용")
        XCTAssertNil(ReplyQuote.parse("> 첫 인용\n> 둘째 인용\n\n본문"), "여러 줄 인용은 답장 머리가 아니다")
        XCTAssertNil(ReplyQuote.parse(">붙은 인용\n\n본문"), "`> ` 모양만")
        XCTAssertNil(ReplyQuote.parse(">  \n\n본문"), "빈 인용")
        XCTAssertNil(ReplyQuote.parse("> 인용\n\n  \n"), "빈 본문")
        XCTAssertEqual(ReplyQuote.visibleText("그냥 글"), "그냥 글")
    }

    /// 안전: 답장 글은 `> `로 시작하므로 승인 명령으로 읽히지 않는다(승인은 버튼·맨 앞 「승인 n」으로만).
    func testQuotedReplyIsNeverAnApprovalCommand() {
        let request = "⚠️ 승인 필요 #1: 방 명령 room_create\n답장: 「승인 1」 또는 「거절 1」 (owner 만)"
        XCTAssertNil(AgentApproval.reply(in: ReplyQuote.compose(name: "공명", original: request, reply: "나중에")))
        XCTAssertNil(AgentApproval.reply(in: ReplyQuote.compose(name: "공명", original: "아무 글", reply: "승인 1")))
    }
}
