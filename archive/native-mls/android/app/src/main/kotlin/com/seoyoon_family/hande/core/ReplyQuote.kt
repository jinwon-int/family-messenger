// 말풍선 답장(#880) — iOS FamilyMLSCore `ReplyQuote` 의 Android 판. android.* 없이 JVM 에서 돈다(ReplyQuoteTest).
package com.seoyoon_family.hande.core

import java.text.BreakIterator

/**
 * 메시지 형식(프로토콜)은 바꾸지 않는다. 답할 글을 본문 맨 앞 마크다운 인용 한 줄로 붙이고 빈 줄 뒤에 내 글을 쓴다(iOS·봇과 같은 모양):
 *
 * ```
 * > 엄마 #1234: 내일 몇 시에 와?
 *
 * 7시쯤!
 * ```
 *
 * `#1234` 는 답한 글의 릴레이 seq(같은 방 안 번호, v2) — 앱은 인용 상자를 누르면 그 글로 가고, 봇은 그 번호로 원문 전체를 찾는다.
 * 번호 없는 v1(`> 엄마: …`)도 그대로 읽는다. 요약은 200자까지. 빈 줄은 내 글이 인용 안으로 이어 붙지 않게 하려는 것이다.
 * 승인 답장 판정은 본문 맨 앞만 보므로 `> ` 로 시작하는 답장은 승인 명령이 되지 않는다.
 */
object ReplyQuote {
    /** 인용 한 줄에 넣는 원문 요약 최대 글자 수(사람이 보는 글자 — 한글·이모지도 한 글자, iOS Character 와 같게). */
    const val SNIPPET_LIMIT = 200

    data class Parsed(
        /** 인용 머리(「엄마 #1234: 내일 몇 시에 와?」 — `> ` 뺀 것). */
        val quote: String,
        /** 답 본문(내 글). */
        val text: String,
        /** 답한 사람 이름(머리에 `이름: ` 이 있으면). null = 이름 없음. */
        val name: String? = null,
        /** 답한 글의 릴레이 seq(v2 `#번호`). null = 번호 없음(v1·이름만). */
        val seq: Long? = null,
        /** 원문 요약(머리에서 이름·번호를 뺀 것). */
        val snippet: String = quote,
    )

    /** 인용 한 줄에 넣을 원문 요약: 원문이 답장이면 그 인용을 뺀 본문, 줄 앞 `>`·줄바꿈은 걷어 한 줄로, 길면 자르고 「…」. */
    fun snippet(body: String): String {
        val base = parse(body)?.text ?: body
        val flat = base.split('\n', '\r')
            .map { line ->
                var s = line.trimSpaces()
                while (s.startsWith(">")) s = s.substring(1).trimSpaces()
                s
            }
            .filter { it.isNotEmpty() }
            .joinToString(" ")
        val count = graphemeCount(flat)
        if (count <= SNIPPET_LIMIT) return flat
        return graphemePrefix(flat, SNIPPET_LIMIT).trimSpaces() + "…"
    }

    /** 보낼 본문: `> 이름 #seq: 요약` + 빈 줄 + 내 글. 이름이 비면 `#seq: 요약`, 번호가 없으면(보내는 중인 글 등) `이름: 요약`. */
    fun compose(name: String, seq: Long? = null, original: String, reply: String): String {
        val s = snippet(original)
        val ref = seq?.takeIf { it > 0 }?.let { "#$it" }
        val label = listOfNotNull(name.ifEmpty { null }, ref).joinToString(" ")
        val head = if (label.isEmpty()) s else "$label: $s"
        return "> $head\n\n$reply"
    }

    /**
     * 답장 글이면 (인용, 본문). 첫 줄 하나만 `> ` 인용이고 바로 빈 줄 뒤에 본문이 있어야 한다.
     * 인용만 있는 글·여러 줄 인용·빈 줄 없는 글은 답장이 아니다(null — 종전처럼 글 그대로).
     */
    fun parse(body: String): Parsed? {
        if (!body.startsWith("> ")) return null
        val gap = body.indexOf("\n\n")
        if (gap < 0) return null
        val head = body.substring(2, gap)
        if (head.any { it == '\n' || it == '\r' }) return null
        val quote = head.trimSpaces()
        val text = body.substring(gap + 2)
        if (quote.isEmpty() || text.isBlank()) return null
        val (name, seq, snippet) = splitHead(quote)
        return Parsed(quote = quote, text = text, name = name, seq = seq, snippet = snippet)
    }

    /** 머리 → (이름, seq, 요약). 첫 `: ` 앞이 라벨 — `이름 #123` · `#123` · `이름`(v1). `: ` 가 없으면 전부 요약. */
    internal fun splitHead(head: String): Triple<String?, Long?, String> {
        val colon = head.indexOf(": ")
        if (colon < 0) return Triple(null, null, head)
        val label = head.substring(0, colon)
        val snippet = head.substring(colon + 2)
        val hash = label.lastIndexOf('#')
        if (hash >= 0 && (hash == 0 || label[hash - 1] == ' ')) {
            val digits = label.substring(hash + 1)
            if (digits.isNotEmpty() && digits.length <= 18 && digits.all { it in '0'..'9' }) {
                val seq = digits.toLongOrNull()
                if (seq != null && seq > 0) {
                    val name = label.substring(0, hash).trimSpaces()
                    return Triple(name.ifEmpty { null }, seq, snippet)
                }
            }
        }
        return Triple(label.ifEmpty { null }, null, snippet)
    }

    /** 화면 밖·부가 쓰임(복사·링크 미리보기)에 쓸 글: 답장이면 내 글만, 아니면 그대로. */
    fun visibleText(body: String): String = parse(body)?.text ?: body

    /** 사람이 보는 글자 수(grapheme). */
    fun graphemeCount(s: String): Int {
        val chars = BreakIterator.getCharacterInstance()
        chars.setText(s)
        var n = 0
        while (chars.next() != BreakIterator.DONE) n++
        return n
    }

    private fun graphemePrefix(s: String, count: Int): String {
        val chars = BreakIterator.getCharacterInstance()
        chars.setText(s)
        var end = 0
        for (i in 0 until count) {
            val next = chars.next()
            if (next == BreakIterator.DONE) return s
            end = next
        }
        return s.substring(0, end)
    }

    /** iOS `.whitespaces`(줄바꿈 제외) 와 같은 범위로 앞뒤를 깎는다. */
    private fun String.trimSpaces(): String = trim { it == '\t' || Character.isSpaceChar(it) }
}
