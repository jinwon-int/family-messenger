// 말풍선 답장 형식(#880) — iOS FamilyMLSCoreTests `ReplyQuoteTests` 이식. 형식이 같아야 iOS·웹·봇과 서로 읽힌다.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ReplyQuoteTest {
    @Test
    fun composeThenParseRoundTrips() {
        val body = ReplyQuote.compose(name = "엄마", original = "내일 몇 시에 와?", reply = "7시쯤!\n늦으면 연락할게")
        assertEquals("> 엄마: 내일 몇 시에 와?\n\n7시쯤!\n늦으면 연락할게", body)
        assertEquals(
            ReplyQuote.Parsed(quote = "엄마: 내일 몇 시에 와?", text = "7시쯤!\n늦으면 연락할게", name = "엄마", seq = null, snippet = "내일 몇 시에 와?"),
            ReplyQuote.parse(body),
        )
        assertEquals("7시쯤!\n늦으면 연락할게", ReplyQuote.visibleText(body))
    }

    @Test
    fun composeWithSeqAndParseBack() {
        val body = ReplyQuote.compose(name = "공명✴️", seq = 1253, original = "TestFlight 업로드까지 끝났습니다.", reply = "어떻게 보여?")
        assertEquals("> 공명✴️ #1253: TestFlight 업로드까지 끝났습니다.\n\n어떻게 보여?", body)
        val parsed = ReplyQuote.parse(body)
        assertEquals("공명✴️", parsed?.name)
        assertEquals(1253L, parsed?.seq)
        assertEquals("TestFlight 업로드까지 끝났습니다.", parsed?.snippet)
        assertEquals("어떻게 보여?", parsed?.text)
        assertEquals("> #7: 안녕\n\n응", ReplyQuote.compose(name = "", seq = 7, original = "안녕", reply = "응"))
        assertEquals(7L, ReplyQuote.parse("> #7: 안녕\n\n응")?.seq)
        assertNull(ReplyQuote.parse("> #7: 안녕\n\n응")?.name)
    }

    @Test
    fun missingOrInvalidSeqIsLeftOut() {
        assertEquals("> 엄마: 안녕\n\n응", ReplyQuote.compose(name = "엄마", seq = null, original = "안녕", reply = "응"), "보내는 중인 글(번호 없음)")
        assertEquals("> 엄마: 안녕\n\n응", ReplyQuote.compose(name = "엄마", seq = -3, original = "안녕", reply = "응"), "음수 = 아직 안 보낸 글")
        assertNull(ReplyQuote.parse("> 엄마 #abc: 안녕\n\n응")?.seq)
        assertEquals("엄마 #abc", ReplyQuote.parse("> 엄마 #abc: 안녕\n\n응")?.name, "숫자가 아니면 이름 그대로")
        assertNull(ReplyQuote.parse("> 엄마#12: 안녕\n\n응")?.seq, "`#` 앞은 띄어쓰기여야")
        assertNull(ReplyQuote.parse("> 엄마 #0: 안녕\n\n응")?.seq)
        assertNull(ReplyQuote.parse("> 엄마 #99999999999999999999: 안녕\n\n응")?.seq, "Long 넘침")
        val noLabel = ReplyQuote.parse("> 콜론 없는 인용\n\n응")
        assertNull(noLabel?.name)
        assertEquals("콜론 없는 인용", noLabel?.snippet)
    }

    @Test
    fun emptyNameQuotesSnippetOnly() {
        assertEquals("> 안녕\n\n응", ReplyQuote.compose(name = "", original = "안녕", reply = "응"))
    }

    @Test
    fun snippetFlattensLinesStripsQuoteMarkersAndTruncates() {
        assertEquals("첫 줄 둘째 줄 인용 줄", ReplyQuote.snippet("첫 줄\n\n  둘째 줄  \n> 인용 줄"))
        val long = "가".repeat(ReplyQuote.SNIPPET_LIMIT + 10)
        val s = ReplyQuote.snippet(long)
        assertEquals(ReplyQuote.SNIPPET_LIMIT + 1, ReplyQuote.graphemeCount(s), "자른 뒤 「…」 한 글자")
        assertTrue(s.endsWith("…"))
        assertEquals(ReplyQuote.SNIPPET_LIMIT, ReplyQuote.graphemeCount(ReplyQuote.snippet("나".repeat(ReplyQuote.SNIPPET_LIMIT))), "한도 안이면 그대로")
    }

    @Test
    fun snippetCountsEmojiAsOneCharacter() {
        // iOS Character(grapheme) 와 같은 기준 — 이모지를 UTF-16 두 칸으로 세어 반쪽에서 자르지 않는다.
        val emoji = "😀".repeat(ReplyQuote.SNIPPET_LIMIT)
        assertEquals(emoji, ReplyQuote.snippet(emoji), "200 글자는 그대로")
        val cut = ReplyQuote.snippet(emoji + "😀")
        assertEquals("😀".repeat(ReplyQuote.SNIPPET_LIMIT) + "…", cut)
    }

    @Test
    fun replyToAReplyQuotesOnlyTheInnerText() {
        val first = ReplyQuote.compose(name = "엄마", original = "내일 몇 시에 와?", reply = "7시쯤!")
        assertEquals("> 아빠: 7시쯤!\n\n좋아", ReplyQuote.compose(name = "아빠", original = first, reply = "좋아"), "인용이 겹겹이 쌓이지 않는다")
        val withSeq = ReplyQuote.compose(name = "엄마", seq = 10, original = "질문", reply = "답")
        assertEquals("> 아빠 #11: 답\n\n좋아", ReplyQuote.compose(name = "아빠", seq = 11, original = withSeq, reply = "좋아"))
    }

    @Test
    fun ordinaryTextAndPlainQuotesAreNotReplies() {
        assertNull(ReplyQuote.parse("그냥 글"))
        assertNull(ReplyQuote.parse("> 인용만 있는 글"), "본문 없음")
        assertNull(ReplyQuote.parse("> 인용\n바로 이어진 줄"), "빈 줄 없음 — 마크다운에선 한 인용")
        assertNull(ReplyQuote.parse("> 첫 인용\n> 둘째 인용\n\n본문"), "여러 줄 인용은 답장 머리가 아니다")
        assertNull(ReplyQuote.parse(">붙은 인용\n\n본문"), "`> ` 모양만")
        assertNull(ReplyQuote.parse(">  \n\n본문"), "빈 인용")
        assertNull(ReplyQuote.parse("> 인용\n\n  \n"), "빈 본문")
        assertEquals("그냥 글", ReplyQuote.visibleText("그냥 글"))
    }

    @Test
    fun choiceAnswerQuotedIsNotAChoiceReply() {
        // 선택지 카드 답 판정은 본문 그대로를 본다 — 인용 머리가 붙은 답장은 「1」 같은 선택지 답으로 읽히지 않아야 한다.
        val body = ReplyQuote.compose(name = "공명", seq = 5, original = "[답변 필요] 하나만 선택\n1. A\n2. B", reply = "1")
        assertTrue(body.startsWith("> "))
        assertEquals("1", ReplyQuote.visibleText(body))
    }
}
