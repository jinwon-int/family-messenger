// 엄격한 JSON 읽개 — 원래 FileV2.kt 안에 있었다(#499). file-v2 판정이 공용 Rust 코어로 옮겨 간 뒤(#366 3e)에도 RoomOrder · PreviewSites ·
// SelfService · LinkPreview · ServerDiscovery 가 쓰므로 내용 그대로 이 파일로 옮겼다. android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

/**
 * RFC 8259 JSON 의 엄격한 부분 구현 — 설명자(≤ 4 KiB) 검증 전용. 웹 `JSON.parse` 가 받는 문서만 받는다(앞뒤 JSON 공백만 허용,
 * 따옴표 없는 키·작은따옴표·주석·끝 쉼표·NaN 거부). 웹보다 엄격한 점 둘 — 둘 다 송신자(`encodeDescriptor`)가 만들지 않는 모양이다:
 * **같은 키가 두 번 나오면 거부**(`JSON.parse` 는 뒤 값을 쓴다 — 클라이언트마다 다른 blob 을 보는 일을 막으려고 닫는 쪽, FILE-V2.md §1),
 * 앞머리 **BOM(U+FEFF) 거부**(웹 `TextDecoder` 는 떼어 낸다).
 * 값: 객체 → `Map<String, Any?>`, 배열 → `List`, 문자열 → `String`, 숫자 → [Num], `true`/`false` → `Boolean`, `null` → [Null].
 */
internal class StrictJson(private val s: String) {
    class Malformed : Exception()
    class Num(val value: Double)
    object Null

    private var i = 0
    private var depth = 0

    fun parseDocument(): Any? {
        ws()
        val v = value()
        ws()
        if (i != s.length) bad()
        return v
    }

    private fun bad(): Nothing = throw Malformed()
    private fun ws() { while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++ }
    private fun peek(): Char = if (i < s.length) s[i] else bad()

    private fun value(): Any? = when (peek()) {
        '{' -> nested { obj() }
        '[' -> nested { arr() }
        '"' -> str()
        't' -> literal("true", true)
        'f' -> literal("false", false)
        'n' -> literal("null", Null)
        else -> num()
    }

    private inline fun <T> nested(body: () -> T): T {
        if (++depth > 32) bad()
        return body().also { depth-- }
    }

    private fun literal(word: String, v: Any): Any {
        if (!s.startsWith(word, i)) bad()
        i += word.length
        return v
    }

    private fun obj(): Map<String, Any?> {
        i++ // {
        val out = LinkedHashMap<String, Any?>()
        ws()
        if (peek() == '}') { i++; return out }
        while (true) {
            ws()
            if (peek() != '"') bad()
            val k = str()
            ws()
            if (peek() != ':') bad()
            i++
            ws()
            val v = value()
            if (out.containsKey(k)) bad()
            out[k] = v
            ws()
            when (peek()) {
                ',' -> i++
                '}' -> { i++; return out }
                else -> bad()
            }
        }
    }

    private fun arr(): List<Any?> {
        i++ // [
        val out = ArrayList<Any?>()
        ws()
        if (peek() == ']') { i++; return out }
        while (true) {
            ws()
            out += value()
            ws()
            when (peek()) {
                ',' -> i++
                ']' -> { i++; return out }
                else -> bad()
            }
        }
    }

    private fun str(): String {
        i++ // "
        val b = StringBuilder()
        while (true) {
            val c = peek()
            i++
            when {
                c == '"' -> return b.toString()
                c == '\\' -> {
                    val e = peek()
                    i++
                    when (e) {
                        '"' -> b.append('"')
                        '\\' -> b.append('\\')
                        '/' -> b.append('/')
                        'b' -> b.append('\b')
                        'f' -> b.append('\u000c')
                        'n' -> b.append('\n')
                        'r' -> b.append('\r')
                        't' -> b.append('\t')
                        'u' -> {
                            if (i + 4 > s.length) bad()
                            var code = 0
                            for (k in 0 until 4) {
                                val d = Character.digit(s[i + k], 16)
                                if (d < 0) bad()
                                code = code * 16 + d
                            }
                            i += 4
                            b.append(code.toChar())
                        }
                        else -> bad()
                    }
                }
                c < ' ' -> bad() // 이스케이프하지 않은 제어 문자
                else -> b.append(c)
            }
        }
    }

    private fun num(): Num {
        val start = i
        if (i < s.length && s[i] == '-') i++
        when {
            i < s.length && s[i] == '0' -> i++
            i < s.length && s[i] in '1'..'9' -> while (i < s.length && s[i].isAsciiDigit()) i++
            else -> bad()
        }
        if (i < s.length && s[i] == '.') {
            i++
            if (!(i < s.length && s[i].isAsciiDigit())) bad()
            while (i < s.length && s[i].isAsciiDigit()) i++
        }
        if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
            i++
            if (i < s.length && (s[i] == '+' || s[i] == '-')) i++
            if (!(i < s.length && s[i].isAsciiDigit())) bad()
            while (i < s.length && s[i].isAsciiDigit()) i++
        }
        return Num(s.substring(start, i).toDouble())
    }

    private fun Char.isAsciiDigit() = this in '0'..'9'
}
