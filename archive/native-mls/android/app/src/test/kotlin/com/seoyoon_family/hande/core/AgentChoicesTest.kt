// agent-choices-v1(#620) 판정 고정 — 웹·iOS 와 같은 공유 벡터 `archive/native-mls/tests/fixtures/agent-choices-vectors.json` 을 그대로 돌린다.
// JVM 단위 테스트의 org.json 은 Android 스텁(호출하면 예외)이라 아주 작은 JSON 읽개를 여기 둔다(객체·배열·문자열·정수·null·참거짓만).
package com.seoyoon_family.hande.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

class AgentChoicesTest {
    private val fixture: Map<*, *> by lazy {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val f = File(dir, "archive/native-mls/tests/fixtures/agent-choices-vectors.json")
            if (f.isFile) return@lazy MiniJson(f.readText(Charsets.UTF_8)).parse() as Map<*, *>
            dir = dir.parentFile
        }
        fail("agent-choices-vectors.json not found above ${File(".").absolutePath}")
    }

    @Test fun parseVectors() {
        val cases = fixture["parse"] as List<*>
        assertTrue(cases.size >= 20, "벡터가 비어 있지 않다")
        for (c in cases) {
            c as Map<*, *>
            val name = c["name"] as String
            val got = AgentChoices.parse(c["text"] as String)
            val expected = c["expected"] as Map<*, *>?
            if (expected == null) {
                assertNull(got, name)
                continue
            }
            val items = (expected["items"] as List<*>).map {
                it as Map<*, *>
                AgentChoiceItem((it["number"] as Long).toInt(), it["label"] as String)
            }
            val recommended = (expected["recommended"] as Long?)?.toInt()
            assertEquals(AgentChoices(items, recommended), got, name)
        }
    }

    @Test fun replyVectors() {
        for (c in fixture["reply"] as List<*>) {
            c as Map<*, *>
            val text = c["text"] as String
            val count = (c["count"] as Long).toInt()
            val expected = (c["expected"] as List<*>?)?.map { (it as Long).toInt() }
            assertEquals(expected, AgentChoices.reply(text, count), "reply('$text', $count)")
        }
    }

    @Test fun composeVectors() {
        val cases = fixture["compose"] as List<*>
        assertTrue(cases.isNotEmpty(), "compose 벡터가 비어 있지 않다")
        for (c in cases) {
            c as Map<*, *>
            val numbers = (c["numbers"] as List<*>).map { (it as Long).toInt() }
            assertEquals(c["expected"] as String, AgentChoices.compose(numbers), "compose($numbers)")
        }
    }

    @Test fun composeRoundTripsThroughReply() {
        for (picked in listOf(setOf(2), setOf(3, 1), setOf(1, 2, 3))) {
            assertEquals(picked.sorted(), AgentChoices.reply(AgentChoices.compose(picked), 3), "$picked")
        }
    }

    private val question = "어떻게 할까요?\n1. 유지\n2. 롤백 (권장)\n3. 보류"
    private fun agent(seq: Long, text: String = question) = MessageUi(seq, "gongmyoung-ab12", text, mine = false)
    private fun me(seq: Long, text: String, attachment: Boolean = false) = MessageUi(seq, "owner-cd34", text, mine = true, attachment = attachment)
    private fun person(seq: Long, text: String) = MessageUi(seq, "jungin-ef56", text, mine = false)

    @Test fun openWhenNothingFollows() {
        val cards = AgentChoices.cards(listOf(me(1, "상태?"), agent(2)))
        assertNull(cards[0])
        val card = cards[1]!!
        assertEquals(AgentChoices.State.Open, card.state)
        assertEquals(3, card.choices.items.size)
        assertEquals(2, card.choices.recommended)
        assertEquals("롤백 (권장)", card.choices.labelOf(2))
    }

    @Test fun answeredWhenMyNextMessageIsTheNumber() {
        for (reply in listOf("2", " 2번 ", "2.", "2 번.")) {
            val cards = AgentChoices.cards(listOf(agent(1), me(2, reply)))
            assertEquals(AgentChoices.State.Answered(listOf(2)), cards[0]!!.state, reply)
            assertNull(cards[1])
        }
    }

    @Test fun answeredWithSeveralNumbers() {
        for (reply in listOf("1, 3", "3,1", "1 3", "1/3", "1번, 3번", "3, 1, 3.")) {
            val cards = AgentChoices.cards(listOf(agent(1), me(2, reply)))
            assertEquals(AgentChoices.State.Answered(listOf(1, 3)), cards[0]!!.state, reply)
        }
        val all = AgentChoices.cards(listOf(agent(1), me(2, "1 → 2 → 3")))
        assertEquals(AgentChoices.State.Answered(listOf(1, 2, 3)), all[0]!!.state)
    }

    @Test fun closedWhenNextIsSomethingElse() {
        val cases = listOf(
            "다른 사람의 숫자" to person(2, "2"),
            "범위 밖" to me(2, "4"),
            "여럿 중 하나가 범위 밖" to me(2, "1, 4"),
            "끝이 구분자" to me(2, "1,"),
            "하이픈은 구분자가 아님" to me(2, "1-2"),
            "문장" to me(2, "2번으로 해 주세요"),
            "첨부" to me(2, "2", attachment = true),
            "에이전트의 다음 글" to agent(2, "작업을 시작합니다."),
        )
        for ((name, next) in cases) {
            assertNull(AgentChoices.cards(listOf(agent(1), next))[0], name)
        }
        // 바로 다음 글만 본다 — 남의 글 뒤에 온 내 답은 answered 가 아니다.
        assertNull(AgentChoices.cards(listOf(agent(1), person(2, "음"), me(3, "1")))[0])
    }

    @Test fun onlyAgentTextMessagesGetCards() {
        val cards = AgentChoices.cards(
            listOf(
                person(1, question),
                me(2, question),
                MessageUi(3, "gongmyoung-ab12", question, mine = false, attachment = true),
                MessageUi(4, "bot-seoseo-1", question, mine = false),
            ),
        )
        assertEquals(listOf(null, null, null), cards.take(3))
        assertEquals(AgentChoices.State.Open, cards[3]!!.state, "옛 bot-<node> 기기도 에이전트")
    }

    @Test fun earlierAnsweredAndLaterOpenCoexist() {
        val cards = AgentChoices.cards(listOf(agent(1), me(2, "1"), agent(3)))
        assertEquals(AgentChoices.State.Answered(listOf(1)), cards[0]!!.state)
        assertEquals(AgentChoices.State.Open, cards[2]!!.state)
    }
}

/** 테스트 전용 최소 JSON 읽개: 객체 → Map, 배열 → List, 문자열 → String, 정수 → Long, true/false → Boolean, null → null. */
private class MiniJson(private val s: String) {
    private var i = 0

    fun parse(): Any? {
        val v = value()
        ws()
        check(i == s.length) { "trailing data at $i" }
        return v
    }

    private fun ws() {
        while (i < s.length && s[i] in " \t\r\n") i++
    }

    private fun value(): Any? {
        ws()
        check(i < s.length) { "unexpected end" }
        return when (val c = s[i]) {
            '{' -> obj()
            '[' -> arr()
            '"' -> str()
            't' -> lit("true", true)
            'f' -> lit("false", false)
            'n' -> lit("null", null)
            else -> if (c == '-' || c in '0'..'9') num() else error("unexpected '$c' at $i")
        }
    }

    private fun lit(word: String, v: Any?): Any? {
        check(s.startsWith(word, i)) { "bad literal at $i" }
        i += word.length
        return v
    }

    private fun num(): Long {
        val start = i
        if (s[i] == '-') i++
        while (i < s.length && s[i] in '0'..'9') i++
        return s.substring(start, i).toLong()
    }

    private fun str(): String {
        i++ // "
        val sb = StringBuilder()
        while (true) {
            check(i < s.length) { "unterminated string" }
            val c = s[i++]
            when (c) {
                '"' -> return sb.toString()
                '\\' -> {
                    when (val e = s[i++]) {
                        'n' -> sb.append('\n')
                        'r' -> sb.append('\r')
                        't' -> sb.append('\t')
                        'b' -> sb.append('\b')
                        'f' -> sb.append('\u000C')
                        '/' -> sb.append('/')
                        '\\' -> sb.append('\\')
                        '"' -> sb.append('"')
                        'u' -> {
                            sb.append(s.substring(i, i + 4).toInt(16).toChar())
                            i += 4
                        }
                        else -> error("bad escape \\$e at $i")
                    }
                }
                else -> sb.append(c)
            }
        }
    }

    private fun arr(): List<Any?> {
        i++ // [
        val out = ArrayList<Any?>()
        ws()
        if (s[i] == ']') { i++; return out }
        while (true) {
            out += value()
            ws()
            when (s[i++]) {
                ',' -> continue
                ']' -> return out
                else -> error("expected , or ] at ${i - 1}")
            }
        }
    }

    private fun obj(): Map<String, Any?> {
        i++ // {
        val out = LinkedHashMap<String, Any?>()
        ws()
        if (s[i] == '}') { i++; return out }
        while (true) {
            ws()
            check(s[i] == '"') { "expected key at $i" }
            val k = str()
            ws()
            check(s[i++] == ':') { "expected : at ${i - 1}" }
            out[k] = value()
            ws()
            when (s[i++]) {
                ',' -> continue
                '}' -> return out
                else -> error("expected , or } at ${i - 1}")
            }
        }
    }
}
