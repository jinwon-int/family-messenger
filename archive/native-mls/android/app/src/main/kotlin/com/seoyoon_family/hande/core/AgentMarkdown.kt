// 에이전트 답장의 마크다운 → 블록·줄 안 조각(#887 1단계). 웹 `web/hande/agent-markdown.js` 를 그대로 옮긴 순수 Kotlin
// (블록 규칙의 원본은 iOS `FamilyMLSCore/Agent/AgentMarkdown.swift`, #405 P1) — 세 화면이 같은 글을 같게 나눈다.
// 받은 글은 신뢰하지 않는다: 여기서는 문자열만 돌려주고 화면(`ui/AgentMarkdownView.kt`)이 글자로만 그린다(HTML 해석·원격 이미지 없음).
// 이미지 문법은 글자 그대로. 링크 문법 `[글자](http(s)://…)` 는 LINK 조각 — 주소 규칙은 `TextLinks.agentUrl`(오너 2026-11-16), 그 밖의 스킴은 글자 그대로.
// android.* · Compose 없음 → JVM 테스트(`AgentMarkdownTest`, 공유 벡터 `tests/fixtures/agent-markdown-vectors.json`).
package com.seoyoon_family.hande.core

import java.util.regex.Pattern

object AgentMarkdown {
    /** 표가 아무리 길어도 화면이 감당할 만큼만(열 8 · 행 60). 넘치는 행은 버리고 끝에 "…" 행을 둔다. */
    const val MAX_COLUMNS = 8
    const val MAX_ROWS = 60
    /** 이보다 긴 글(UTF-16 길이, 웹 `String.length` 와 같다)은 나누지 않고 평문으로 그린다(렌더 비용 상한). */
    const val MAX_SOURCE = 100_000

    sealed interface Block {
        data class Heading(val level: Int, val text: String) : Block
        data class Paragraph(val text: String) : Block
        /** 웹의 `list` 블록. */
        data class Items(val items: List<Item>) : Block
        data class Table(val header: List<String>, val rows: List<List<String>>) : Block
        data class Code(val text: String) : Block
        data class Quote(val text: String) : Block
        data object Rule : Block
    }

    /** 목록 한 항목: 들여쓰기 단계(0~4) · 번호 표시(`1.` `3)`, 글머리표면 null) · 글. */
    data class Item(val level: Int, val marker: String?, val text: String)

    enum class Style { TEXT, CODE, STRONG, EM, DEL, LINK }

    /** 줄 안 조각(바깥 한 겹). [href] 는 LINK 일 때만. */
    data class Span(val style: Style, val text: String, val href: String? = null)

    private fun isBlank(ch: Char) = ch == ' ' || ch == '\t'
    private fun trimWs(s: String) = s.trim { isBlank(it) }

    fun parseBlocks(source: String?): List<Block> {
        val lines = (source ?: "").replace("\r\n", "\n").split('\n')
        val blocks = ArrayList<Block>()
        val paragraph = ArrayList<String>()
        // 목록 항목의 글은 이어지는 줄이 붙을 수 있어 StringBuilder 로 모은다(줄마다 문자열을 새로 잇지 않는다).
        val list = ArrayList<Triple<Int, String?, StringBuilder>>()
        val quote = ArrayList<String>()
        var i = 0

        fun flushParagraph() { if (paragraph.isNotEmpty()) { blocks += Block.Paragraph(paragraph.joinToString("\n")); paragraph.clear() } }
        fun flushList() { if (list.isNotEmpty()) { blocks += Block.Items(list.map { (level, marker, text) -> Item(level, marker, text.toString()) }); list.clear() } }
        fun flushQuote() { if (quote.isNotEmpty()) { blocks += Block.Quote(quote.joinToString("\n")); quote.clear() } }
        fun flushAll() { flushParagraph(); flushList(); flushQuote() }

        while (i < lines.size) {
            val line = lines[i]
            val trimmed = trimWs(line)

            // 코드 울타리: 닫는 ``` 까지(없으면 끝까지) 그대로.
            if (trimmed.startsWith("```")) {
                flushAll()
                val body = ArrayList<String>()
                i += 1
                while (i < lines.size && !trimWs(lines[i]).startsWith("```")) { body += lines[i]; i += 1 }
                blocks += Block.Code(body.joinToString("\n"))
                i += 1
                continue
            }
            if (trimmed.isEmpty()) { flushAll(); i += 1; continue }

            // 표: 이 줄에 `|` 가 있고 다음 줄이 구분선(|---|:--:|)이면.
            if (trimmed.contains('|') && i + 1 < lines.size && isTableSeparator(lines[i + 1])) {
                flushAll()
                val header = cells(trimmed).take(MAX_COLUMNS)
                val rows = ArrayList<List<String>>()
                var truncated = false
                i += 2
                while (i < lines.size) {
                    val row = trimWs(lines[i])
                    if (row.isEmpty() || !row.contains('|')) break
                    if (rows.size < MAX_ROWS) rows += normalize(cells(row), header.size) else truncated = true
                    i += 1
                }
                if (truncated) rows += normalize(listOf("…"), header.size)
                blocks += Block.Table(header, rows)
                continue
            }
            val level = headingLevel(trimmed)
            if (level != null) {
                flushAll()
                blocks += Block.Heading(level, trimWs(trimmed.trimStart('#')))
                i += 1
                continue
            }
            if (isRule(trimmed)) { flushAll(); blocks += Block.Rule; i += 1; continue }
            if (trimmed.startsWith(">")) {
                flushParagraph(); flushList()
                quote += trimWs(trimmed.substring(1))
                i += 1
                continue
            }
            val item = listItem(line)
            if (item != null) {
                flushParagraph(); flushQuote()
                list += Triple(item.level, item.marker, StringBuilder(item.text))
                i += 1
                continue
            }
            // 목록 바로 뒤의 들여쓴 이어지는 줄은 앞 항목에 붙인다.
            if (list.isNotEmpty() && isBlank(line[0])) {
                list.last().third.append('\n').append(trimmed)
                i += 1
                continue
            }
            flushList(); flushQuote()
            paragraph += line
            i += 1
        }
        flushAll()
        return blocks
    }

    /**
     * 블록으로 나눌 가치가 있으면 그 블록들, 아니면 null — 평범한 대화(서식 없음)·빈 글·[MAX_SOURCE] 를 넘는 글은 지금처럼 한 덩어리 평문으로 둔다.
     * 화면은 이 한 번의 결과로 「서식 글인가」와 「무엇을 그릴까」를 함께 얻는다(같은 글을 두 번 나누지 않는다).
     */
    fun blocksIfMarkdown(source: String?): List<Block>? {
        if (source.isNullOrEmpty() || source.length > MAX_SOURCE) return null
        val blocks = parseBlocks(source)
        if (blocks.any { it !is Block.Paragraph }) return blocks
        return if (blocks.any { block -> inlineSpans((block as Block.Paragraph).text).any { it.style != Style.TEXT } }) blocks else null
    }

    /** 웹 `hasMarkdown` 과 같은 판정. */
    fun hasMarkdown(source: String?): Boolean = blocksIfMarkdown(source) != null

    fun cells(row: String): List<String> {
        var s = trimWs(row)
        if (s.startsWith("|")) s = s.substring(1)
        if (s.endsWith("|") && !s.endsWith("\\|")) s = s.substring(0, s.length - 1)
        // `\|` 는 칸 안의 글자.
        return s.replace("\\|", "\u0000").split('|').map { trimWs(it.replace('\u0000', '|')) }
    }

    fun normalize(row: List<String>, width: Int): List<String> = when {
        width <= 0 -> row
        row.size >= width -> row.take(width)
        else -> row + List(width - row.size) { "" }
    }

    fun isTableSeparator(line: String): Boolean = cells(line).all { part ->
        val p = part.removePrefix(":").removeSuffix(":")
        p.length >= 3 && p.all { it == '-' }
    }

    fun headingLevel(trimmed: String): Int? {
        val hashes = trimmed.indexOfFirst { it != '#' }.let { if (it < 0) trimmed.length else it }
        if (hashes < 1 || hashes > 6) return null
        return if (trimmed.getOrNull(hashes) == ' ') hashes else null
    }

    fun isRule(trimmed: String): Boolean {
        val compact = trimmed.replace(" ", "")
        if (compact.length < 3 || compact[0] !in "-*_") return false
        return compact.all { it == compact[0] }
    }

    fun listItem(line: String): Item? {
        var indent = 0
        var k = 0
        while (k < line.length && isBlank(line[k])) { indent += if (line[k] == '\t') 4 else 1; k += 1 }
        val body = line.substring(k)
        val level = minOf(indent / 2, 4)
        if (body.length > 1 && body[0] in "-*•+" && body[1] == ' ') return Item(level, null, trimWs(body.substring(2)))
        var digits = 0
        while (digits < body.length && digits < 3 && body[digits] in '0'..'9') digits += 1
        if (digits > 0 && body.getOrNull(digits)?.let { it in '0'..'9' } != true) {
            val p = body.getOrNull(digits)
            if ((p == '.' || p == ')') && body.getOrNull(digits + 1) == ' ') {
                return Item(level, body.substring(0, digits) + p, trimWs(body.substring(digits + 2)))
            }
        }
        return null
    }

    /**
     * 줄 안 서식: `코드` · 별표 둘 또는 밑줄 둘(굵게) · 별표 하나(기울임) · 물결 둘(취소선). 여기서는 바깥 한 겹만 나누고, 안쪽(코드 제외)은 [runs] 가 같은 함수로 다시 나눈다.
     * 짝이 없는 기호는 글자 그대로 둔다. 밑줄 하나(_x_)는 snake_case 를 깨뜨리므로 다루지 않는다.
     * `[글자](http(s)://…)` 는 LINK(href) — 앞이 `!`(이미지 문법)면 글자 그대로.
     *
     * 판정은 웹의 정규식 다섯 개와 같되(아래 [InlineScanner] 의 각 함수에 원문을 적었다) 정규식으로 돌리지 않는다: 닫는 기호가 없는 여는 기호마다
     * 글 끝까지 다시 훑으면 글 길이의 제곱이 되어(16KB 글에 수 초) 화면 스레드를 붙잡는다. 여기서는 닫는 자리를 한 번 찾은 결과를 이어 써서 글 길이에 비례한다.
     */
    fun inlineSpans(text: String?): List<Span> {
        val source = text ?: ""
        val scanner = InlineScanner(source)
        val spans = ArrayList<Span>()
        var plainFrom = 0
        var i = 0
        while (i < source.length) {
            val match = when (source[i]) {
                '[' -> if (i == 0 || source[i - 1] != '!') linkMatch(source, i) else null
                '`' -> scanner.code(i)
                '*' -> scanner.doubled(i, '*', Style.STRONG) ?: scanner.em(i)
                '_' -> scanner.doubled(i, '_', Style.STRONG)
                '~' -> scanner.doubled(i, '~', Style.DEL)
                else -> null
            }
            if (match == null) { i += 1; continue }
            if (i > plainFrom) spans += Span(Style.TEXT, source.substring(plainFrom, i))
            spans += match.first
            i += match.second
            plainFrom = i
        }
        if (source.length > plainFrom) spans += Span(Style.TEXT, source.substring(plainFrom))
        return spans
    }

    /** 웹(JS)의 `\s` 와 같은 공백 집합 — Java·ICU 의 기본 `\s` 는 ASCII 공백만이라 전각 공백(U+3000) 같은 글자에서 판정이 갈린다. */
    private fun isSpace(c: Char): Boolean = when (c) {
        ' ', '\t', '\n', '\u000B', '\u000C', '\r', ' ', ' ', ' ', ' ', ' ', ' ', '　', '﻿' -> true
        else -> c in ' '..' '
    }

    /** 글 하나의 줄 안 판정 — 닫는 자리 찾기 결과를 기억한다(한 번의 [inlineSpans] 동안 여는 자리는 앞에서 뒤로만 간다). 반환 = 조각 + 먹은 길이. */
    private class InlineScanner(private val s: String) {
        /** 닫는 `**`·`__`·`~~` 찾기 기억(기호별): `from` 이상에서 처음 나오는 닫는 자리 `at`(없으면 글 길이). */
        private class Closer(var from: Int = -1, var at: Int = -1)
        private val closers = HashMap<Char, Closer>()
        /** 백틱 덩어리(끊기지 않는 한 줄) — 길이 → 시작 위치들(오름차순). 처음 백틱을 만났을 때 한 번 만든다. */
        private val tickRuns: Map<Int, IntArray> by lazy {
            val found = HashMap<Int, ArrayList<Int>>()
            var k = 0
            while (k < s.length) {
                if (s[k] != '`') { k += 1; continue }
                val start = k
                while (k < s.length && s[k] == '`') k += 1
                found.getOrPut(k - start) { ArrayList() } += start
            }
            found.mapValues { it.value.toIntArray() }
        }

        /** [from] 이상에서 처음 나오는 닫는 `mm`: 바로 앞 글자가 공백도 [m] 도 아닌 자리. 없으면 글 길이. */
        private fun closer(m: Char, from: Int): Int {
            val memo = closers.getOrPut(m) { Closer() }
            if (memo.from in 0..from && from <= memo.at) return memo.at
            var c = s.indexOf(m, from)
            while (c >= 0) {
                if (c + 1 < s.length && s[c + 1] == m && s[c - 1] != m && !isSpace(s[c - 1])) break
                c = s.indexOf(m, c + 1)
            }
            memo.from = from
            memo.at = if (c < 0) s.length else c
            return memo.at
        }

        /**
         * 굵게·취소선 — 웹 `^\*\*(?![\s*])([\s\S]*?[^\s*])\*\*` (`__` · `~~` 도 같은 모양): 여는 `mm` 바로 뒤가 공백·[m] 이 아니고,
         * 그 뒤 가장 가까운 닫는 `mm`(바로 앞이 공백·[m] 이 아님)까지. 안쪽은 한 글자 이상.
         */
        fun doubled(i: Int, m: Char, style: Style): Pair<Span, Int>? {
            if (i + 2 >= s.length || s[i + 1] != m) return null
            val first = s[i + 2]
            if (first == m || isSpace(first)) return null
            val c = closer(m, i + 3)
            if (c >= s.length) return null
            return Span(style, s.substring(i + 2, c)) to (c + 2 - i)
        }

        /**
         * 기울임 — 웹 `^\*(?![\s*])([^*\n]*?[^\s*])\*(?!\*)`: 여는 `*` 바로 뒤가 공백·`*` 이 아니고, 같은 줄의 다음 `*` 까지(그 앞은 공백이 아니고 뒤는 `*` 가 아님).
         * 안쪽에 `*` 를 둘 수 없으므로 닫는 자리 후보는 다음 `*` 하나뿐이다.
         */
        fun em(i: Int): Pair<Span, Int>? {
            if (i + 1 >= s.length) return null
            val first = s[i + 1]
            if (first == '*' || isSpace(first)) return null
            var q = i + 2
            while (q < s.length && s[q] != '*' && s[q] != '\n') q += 1
            if (q >= s.length || s[q] != '*' || isSpace(s[q - 1])) return null
            if (q + 1 < s.length && s[q + 1] == '*') return null
            return Span(Style.EM, s.substring(i + 1, q)) to (q + 1 - i)
        }

        /**
         * 코드 — 웹 ``^(`+)(?!`)([\s\S]*?[^`])\1(?!`)``: 백틱 n개로 열면(이 자리부터 덩어리 끝까지가 n) 그 뒤 가장 가까운 「딱 n개짜리 덩어리」로 닫는다.
         * 안쪽은 서식 해석 없음. 양끝에 한 칸씩 둔 코드(`` ` a`b ` ``)는 그 한 칸을 뗀다(안이 공백뿐이면 그대로).
         */
        fun code(i: Int): Pair<Span, Int>? {
            var end = i
            while (end < s.length && s[end] == '`') end += 1
            if (end >= s.length) return null
            val n = end - i
            val starts = tickRuns[n] ?: return null
            var lo = 0
            var hi = starts.size
            while (lo < hi) {   // 처음으로 end 보다 뒤에서 시작하는 덩어리
                val mid = (lo + hi) ushr 1
                if (starts[mid] > end) hi = mid else lo = mid + 1
            }
            if (lo >= starts.size) return null
            val c = starts[lo]
            val inner = s.substring(end, c)
            val padded = inner.length >= 3 && inner.first() == ' ' && inner.last() == ' ' && (1 until inner.length - 1).any { inner[it] != ' ' }
            return Span(Style.CODE, if (padded) inner.substring(1, inner.length - 1) else inner) to (c + n - i)
        }
    }

    // 웹(JS)의 `\s` 를 정규식 문자 집합 안에 적은 것([isSpace] 와 같은 집합).
    private const val WS = " \\t\\n\\u000B\\f\\r\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"

    /**
     * `[글자](주소)` — 주소 안 괄호는 한 겹까지(위키백과 `Foo_(bar)`). 웹 `^\[([^[\]\n]+)\]\((https?:\/\/[^\s()<>]+(?:\([^\s()<>]*\)[^\s()<>]*)*)\)` (대소문자 무시)와 같다.
     * 반복은 되돌아가지 않게(`++` `*+`) 적었다: 주소 조각을 덜 먹어도 그 자리는 `)` 가 아니라서 결과가 같고, 괄호가 수없이 이어진 주소에서 스택을 쌓지 않는다.
     */
    private val LINK: Pattern = Pattern.compile(
        "\\[([^\\[\\]\\n]++)\\]\\((https?://[^$WS()<>]++(?:\\([^$WS()<>]*+\\)[^$WS()<>]*+)*+)\\)",
        Pattern.CASE_INSENSITIVE,
    )

    /** 열 수 없는 주소(`TextLinks.agentUrl` — http·https 가 아니거나 호스트 없음)면 null(글자 그대로). */
    private fun linkMatch(source: String, at: Int): Pair<Span, Int>? {
        val m = LINK.matcher(source).region(at, source.length)
        if (!m.lookingAt()) return null
        val href = TextLinks.agentUrl(m.group(2)) ?: return null
        return Span(Style.LINK, m.group(1), href) to (m.end() - at)
    }

    /**
     * 화면이 그릴 글 한 토막: 글자 + 겹친 서식 + (있으면) 열 주소. 웹 `ui.js inlineNodes` 를 펴 놓은 것.
     * 코드 안은 해석하지 않는다(주소도 링크로 만들지 않는다). 링크 조각의 글자는 다시 나누지 않는다.
     */
    data class Run(
        val text: String,
        val strong: Boolean = false,
        val em: Boolean = false,
        val del: Boolean = false,
        val code: Boolean = false,
        val href: String? = null,
    )

    /**
     * 글 한 덩어리(문단·제목·목록 항목·인용) → 그릴 토막들. 굵게·기울임·취소선 안쪽은 같은 함수로 다시 나누고,
     * 평문 토막 속 `http(s)://…` 주소는 `TextLinks.agentLinks` 규칙으로 링크 토막이 된다(서식 없는 에이전트 글과 같은 규칙).
     * 겹침은 깊어지지 않는다: 닫는 기호는 늘 가장 가까운 것이라 같은 기호가 제 안에 다시 들어갈 수 없다 — 많아야 `__` · `~~` · 별표 둘 · 별표 하나의 네 겹.
     */
    fun runs(text: String): List<Run> {
        val out = ArrayList<Run>()
        collectRuns(text, Run(""), out)
        return out
    }

    private fun collectRuns(text: String, outer: Run, out: MutableList<Run>) {
        for (span in inlineSpans(text)) {
            when (span.style) {
                Style.TEXT -> plainRuns(span.text, outer, out)
                Style.CODE -> out += outer.copy(text = span.text, code = true)
                Style.LINK -> out += outer.copy(text = span.text, href = span.href)
                Style.STRONG -> collectRuns(span.text, outer.copy(strong = true), out)
                Style.EM -> collectRuns(span.text, outer.copy(em = true), out)
                Style.DEL -> collectRuns(span.text, outer.copy(del = true), out)
            }
        }
    }

    private fun plainRuns(text: String, outer: Run, out: MutableList<Run>) {
        var last = 0
        for (link in TextLinks.agentLinks(text)) {
            if (link.start > last) out += outer.copy(text = text.substring(last, link.start))
            out += outer.copy(text = text.substring(link.start, link.end), href = link.url)
            last = link.end
        }
        if (last < text.length) out += outer.copy(text = text.substring(last))
    }
}
