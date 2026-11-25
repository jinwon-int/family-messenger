// 에이전트 마크다운 파서(#887 1단계) — 웹과 같은 공유 벡터 `archive/native-mls/tests/fixtures/agent-markdown-vectors.json` 을 그대로 돌리고,
// Android 고유 부분(상한 · 그릴 토막 [AgentMarkdown.runs] · 주소 규칙)은 아래에서 따로 고정한다.
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.core.AgentMarkdown.Block
import com.seoyoon_family.hande.core.AgentMarkdown.Run
import com.seoyoon_family.hande.core.AgentMarkdown.Style
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

class AgentMarkdownTest {
    private val fixture: Map<*, *> by lazy {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val f = File(dir, "archive/native-mls/tests/fixtures/agent-markdown-vectors.json")
            if (f.isFile) return@lazy MiniJson(f.readText(Charsets.UTF_8)).parse() as Map<*, *>
            dir = dir.parentFile
        }
        fail("agent-markdown-vectors.json not found above ${File(".").absolutePath}")
    }

    private fun strings(v: Any?): List<String> = (v as List<*>).map { it as String }

    /** 벡터의 블록 한 개(웹 반환값 모양) → Kotlin 블록. 모르는 type 은 벡터 오류다. */
    private fun block(v: Any?): Block {
        v as Map<*, *>
        return when (val type = v["type"] as String) {
            "heading" -> Block.Heading((v["level"] as Number).toInt(), v["text"] as String)
            "paragraph" -> Block.Paragraph(v["text"] as String)
            "list" -> Block.Items((v["items"] as List<*>).map { item ->
                item as Map<*, *>
                AgentMarkdown.Item((item["level"] as Number).toInt(), item["marker"] as String?, item["text"] as String)
            })
            "table" -> Block.Table(strings(v["header"]), (v["rows"] as List<*>).map(::strings))
            "code" -> Block.Code(v["text"] as String)
            "quote" -> Block.Quote(v["text"] as String)
            "rule" -> Block.Rule
            else -> fail("unknown block type $type")
        }
    }

    private fun span(v: Any?): AgentMarkdown.Span {
        v as Map<*, *>
        val style = when (val name = v["style"] as String) {
            "text" -> Style.TEXT
            "code" -> Style.CODE
            "strong" -> Style.STRONG
            "em" -> Style.EM
            "del" -> Style.DEL
            "link" -> Style.LINK
            else -> fail("unknown span style $name")
        }
        return AgentMarkdown.Span(style, v["text"] as String, v["href"] as String?)
    }

    @Test fun limitsMatchTheSharedVectors() {
        val limits = fixture["limits"] as Map<*, *>
        assertEquals((limits["max_columns"] as Number).toInt(), AgentMarkdown.MAX_COLUMNS)
        assertEquals((limits["max_rows"] as Number).toInt(), AgentMarkdown.MAX_ROWS)
        assertEquals((limits["max_source"] as Number).toInt(), AgentMarkdown.MAX_SOURCE)
    }

    @Test fun parseBlocksVectors() {
        val cases = fixture["blocks"] as List<*>
        assertTrue(cases.size >= 30)
        for (c in cases) {
            c as Map<*, *>
            assertEquals((c["blocks"] as List<*>).map(::block), AgentMarkdown.parseBlocks(c["text"] as String), c["name"] as String)
        }
    }

    @Test fun inlineSpansVectors() {
        val cases = fixture["inline"] as List<*>
        assertTrue(cases.size >= 30)
        for (c in cases) {
            c as Map<*, *>
            assertEquals((c["spans"] as List<*>).map(::span), AgentMarkdown.inlineSpans(c["text"] as String), c["name"] as String)
        }
    }

    @Test fun hasMarkdownVectors() {
        val cases = fixture["has_markdown"] as List<*>
        assertTrue(cases.size >= 15)
        for (c in cases) {
            c as Map<*, *>
            val text = c["text"] as String
            assertEquals(c["expected"] as Boolean, AgentMarkdown.hasMarkdown(text), c["name"] as String)
            // 화면이 쓰는 한 번짜리 판정도 같은 답이고, 서식 글이면 parseBlocks 와 같은 블록을 돌려준다.
            assertEquals(if (c["expected"] as Boolean) AgentMarkdown.parseBlocks(text) else null, AgentMarkdown.blocksIfMarkdown(text), c["name"] as String)
        }
    }

    @Test fun sourceLimitFallsBackToPlainText() {
        assertFalse(AgentMarkdown.hasMarkdown(null))
        assertNull(AgentMarkdown.blocksIfMarkdown(null))
        assertEquals(emptyList(), AgentMarkdown.parseBlocks(null))
        assertEquals(emptyList(), AgentMarkdown.inlineSpans(null))
        val head = "**x** "
        // 딱 상한 길이까지는 나눈다. 한 글자라도 넘으면 평문.
        assertTrue(AgentMarkdown.hasMarkdown(head + "a".repeat(AgentMarkdown.MAX_SOURCE - head.length)))
        assertFalse(AgentMarkdown.hasMarkdown(head + "a".repeat(AgentMarkdown.MAX_SOURCE - head.length + 1)))
        // 길이는 UTF-16 단위(웹 String.length 와 같다): 이모지 한 글자 = 2.
        assertFalse(AgentMarkdown.hasMarkdown(head + "😀".repeat((AgentMarkdown.MAX_SOURCE - head.length) / 2 + 1)))
    }

    @Test fun runsFlattenNestedMarkup() {
        assertEquals(
            listOf(Run("a "), Run("b", strong = true), Run(" "), Run("c", code = true), Run(" "), Run("d", em = true), Run(" "), Run("e", del = true)),
            AgentMarkdown.runs("a **b** `c` *d* ~~e~~"),
        )
        // 굵게 안의 코드·기울임은 굵게를 물려받는다. 코드 안은 해석하지 않는다.
        assertEquals(
            listOf(Run("test-rs", strong = true, code = true), Run("라는 방이 ", strong = true), Run("없습니다", strong = true, em = true), Run(".", strong = true)),
            AgentMarkdown.runs("**`test-rs`라는 방이 *없습니다*.**"),
        )
        assertEquals(listOf(Run("**x** https://a.example/x", code = true)), AgentMarkdown.runs("`**x** https://a.example/x`"))
        assertEquals(emptyList(), AgentMarkdown.runs(""))
        assertEquals(listOf(Run("그냥 글")), AgentMarkdown.runs("그냥 글"))
    }

    @Test fun runsLinkRules() {
        // 링크 문법: 글자가 링크. 글자 안의 서식 기호는 다시 나누지 않는다(웹과 같다).
        assertEquals(
            listOf(Run("#825", href = "https://github.com/jinwon-int/family-messenger/pull/825"), Run(" 머지")),
            AgentMarkdown.runs("[#825](https://github.com/jinwon-int/family-messenger/pull/825) 머지"),
        )
        assertEquals(listOf(Run("**굵은** 글자", href = "https://a.example/x")), AgentMarkdown.runs("[**굵은** 글자](https://a.example/x)"))
        // 글 속 주소: 서식 없는 에이전트 글과 같은 규칙(`TextLinks.agentLinks`) — 끝 문장부호는 뺀다. 굵게 안에서도 같다.
        assertEquals(
            listOf(Run("보기 "), Run("https://a.example/x", href = "https://a.example/x"), Run(". 끝")),
            AgentMarkdown.runs("보기 https://a.example/x. 끝"),
        )
        assertEquals(
            listOf(Run("주소 ", strong = true), Run("http://100.64.0.1:8080/x", strong = true, href = "http://100.64.0.1:8080/x")),
            AgentMarkdown.runs("**주소 http://100.64.0.1:8080/x**"),
        )
        assertEquals(
            listOf(Run("보기", strong = true, href = "https://a.example/x"), Run(" 확인", strong = true)),
            AgentMarkdown.runs("**[보기](https://a.example/x) 확인**"),
        )
        // http(s) 가 아닌 스킴·이미지 문법·상대 주소는 글자 그대로(링크 토막 없음).
        for (plain in listOf("[a](javascript:alert(1))", "[a](/relative)", "[a](file:///etc/passwd)", "[a](intent://x#Intent;end)", "[a](content://x/y)")) {
            assertEquals(listOf(Run(plain)), AgentMarkdown.runs(plain), plain)
        }
        // 이미지 문법은 원격 로드 없이 글자 그대로 — 안의 주소는 글 속 주소 규칙으로만 링크가 된다(그림은 불러오지 않는다).
        val image = AgentMarkdown.runs("![p](https://a.example/x.png)")
        assertEquals("![p](https://a.example/x.png)", image.joinToString("") { it.text })
        assertEquals(listOf("https://a.example/x.png"), image.mapNotNull { it.href })
        // 열 수 없는 주소(호스트 없음)는 링크가 아니다.
        assertTrue(AgentMarkdown.runs("[a](https:///x)").none { it.href != null })
        // 어떤 토막이든 주소는 http(s) 로만 시작한다.
        val hostile = "<img src=x onerror=alert(1)> [눌러](javascript:alert(1)) ![p](https://evil/x.png) <script>x</script> [b](HTTPS://A.example/y)"
        for (run in AgentMarkdown.runs(hostile)) run.href?.let { assertTrue(it.startsWith("http://", ignoreCase = true) || it.startsWith("https://", ignoreCase = true), it) }
        assertEquals(hostile.replace("[b](HTTPS://A.example/y)", "b"), AgentMarkdown.runs(hostile).joinToString("") { it.text })
    }

    @Test fun columnWidthsFitContentThenShareSpareSpace() {
        fun widths(natural: List<Int>, cap: Int, available: Int) = AgentMarkdown.columnWidths(natural.toIntArray(), cap, available).toList()
        // 내용이 상한 아래면 내용 너비 그대로 — 자리가 남아도 늘리지 않는다(표는 내용만큼만 차지한다).
        assertEquals(listOf(80, 120, 60), widths(listOf(80, 120, 60), cap = 300, available = 900))
        // 긴 열은 상한에서 줄바꿈. 말풍선에 자리가 없으면 거기서 끝(합이 넘치면 화면이 가로 스크롤).
        assertEquals(listOf(80, 300, 300), widths(listOf(80, 700, 450), cap = 300, available = 600))
        assertEquals(listOf(300, 300, 300, 300), widths(listOf(900, 900, 900, 900), cap = 300, available = 700))
        // 자리가 남으면 줄바꿈된 열에 왼쪽부터 내용 너비까지 돌려준다.
        assertEquals(listOf(80, 700, 300), widths(listOf(80, 700, 450), cap = 300, available = 1080))
        assertEquals(listOf(80, 700, 420), widths(listOf(80, 700, 450), cap = 300, available = 1200))
        assertEquals(listOf(80, 700, 450), widths(listOf(80, 700, 450), cap = 300, available = 5000))
        // 흔한 모양: 짧은 이름 열 + 긴 설명 열 — 설명 열이 말풍선 끝까지 쓴다(더 넓히지는 않는다).
        assertEquals(listOf(150, 750), widths(listOf(150, 1400), cap = 500, available = 900))
        // 제한이 없는 자리(Int.MAX_VALUE)에서도 넘치지 않고 내용 너비로 끝난다. 빈 표·0 너비도 안전하다.
        assertEquals(listOf(80, 700), widths(listOf(80, 700), cap = 300, available = Int.MAX_VALUE))
        assertEquals(emptyList(), widths(emptyList(), cap = 300, available = 900))
        assertEquals(listOf(0, 0), widths(listOf(0, 0), cap = 300, available = 900))
        assertEquals(listOf(80, 300), widths(listOf(80, 700), cap = 300, available = 0))
    }

    @Test fun nestingStaysShallow() {
        // 닫는 기호는 늘 가장 가까운 것이라 같은 기호는 제 안에 다시 들어가지 못한다 — 겹침은 많아야 네 겹(`__` · `~~` · 별표 둘 · 별표 하나).
        assertEquals(
            listOf(Run("a ", strong = true, del = true), Run("x", strong = true, em = true, del = true), Run(" b", strong = true, del = true)),
            AgentMarkdown.runs("__~~**a *x* b**~~__"),
        )
        assertEquals(listOf(Run("a ", strong = true), Run("b", strong = true, del = true), Run(" c", strong = true)), AgentMarkdown.runs("**a ~~b~~ c**"))
        // 겹치려고 번갈아 쌓은 글: 가장 가까운 닫는 기호에서 끊겨 얕게 나뉘고, 글자는 기호만 빠진 채 순서대로 남는다(재귀가 깊어지지 않는다).
        val depth = 20_000
        val open = (0 until depth).joinToString("") { if (it % 2 == 0) "**" else "__" }
        val close = (depth - 1 downTo 0).joinToString("") { if (it % 2 == 0) "**" else "__" }
        val runs = AgentMarkdown.runs("${open}x$close")
        assertTrue(runs.isNotEmpty())
        assertTrue(runs.joinToString("") { it.text }.all { it == '*' || it == '_' || it == 'x' })
    }

    @Test fun pathologicalInputStaysLinear() {
        // 닫히지 않는 여는 기호가 가득한 글(상한 MAX_SOURCE 바로 아래): 여는 기호마다 글 끝까지 다시 훑지 않는다 — 정규식으로 돌리면 이 크기에서 분 단위다.
        val size = AgentMarkdown.MAX_SOURCE
        for (unit in listOf("**a ", "__a ", "~~a ", "*a ", "`a ", "``a` ", "[a](https://a.example/x ", "[a ", "- **a\n", "| **a |\n")) {
            val text = unit.repeat(size / unit.length)
            val started = System.nanoTime()
            AgentMarkdown.blocksIfMarkdown(text)?.forEach { block ->
                when (block) {
                    is Block.Paragraph -> AgentMarkdown.runs(block.text)
                    is Block.Items -> block.items.forEach { AgentMarkdown.runs(it.text) }
                    else -> Unit
                }
            }
            val ms = (System.nanoTime() - started) / 1_000_000
            assertTrue(ms < 3_000, "${unit.trim()} × ${size / unit.length}: $ms ms")
        }
        // 이어지는 줄이 수만 개인 목록 항목 하나도 한 번에 모은다.
        val item = AgentMarkdown.parseBlocks("- a\n" + " b\n".repeat(40_000))
        assertEquals(1, (item.single() as Block.Items).items.size)
        // 괄호가 수없이 이어진 주소도 스택을 쌓지 않고 한 조각으로 끝난다.
        val parens = "[a](https://a.example/" + "(x)".repeat(20_000) + ")"
        assertEquals(1, AgentMarkdown.inlineSpans(parens).size)
    }
}
