// file-v2 분리 첨부 수신(#499, 정본 `archive/native-mls/FILE-V2.md`) — 설명자 검증과 수신 메시지 분류. android.* 없이 JVM 에서 돈다
// (CI `:app:testDebugUnitTest`). 웹 `archive/experiments/openmls-browser/web/file-v2.js` `parseDescriptor` 와 같은 규칙이다.
//
// 바깥 client_id 가 `file-v2-` 로 시작하는 메시지의 평문은 파일을 열 **키**가 든 설명자 JSON 이다. 그래서 이 메시지는 어떤 경우에도
// 글(text)로 저장하거나 보이지 않는다: 설명자가 올바르면 `file-v2` 행(본문 = 자리 표시, 설명자는 attachment 칸), 아니면
// `undecryptable` 행(평문 버림). 파일 바이트를 받아 여는 일(blob GET → sha256 → AES-GCM)은 v1 첨부 미리보기와 함께 C 단계에서 한다.
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.ui.Strings
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.Base64

object FileV2 {
    const val VERSION = 2
    const val MAX_FILE_BYTES = 50L * 1024 * 1024 // #499 오너 결정
    const val MAX_DESCRIPTOR_BYTES = 4096
    const val KEY_BYTES = 32
    const val NONCE_BYTES = 12
    const val MAX_DIMENSION = 20000L
    const val CLIENT_PREFIX = "file-v2-"

    private val REQUIRED = setOf("v", "blob", "size", "key", "nonce")
    private val ALLOWED = REQUIRED + setOf("mime", "name", "w", "h")
    private val CLIENT_ID = Regex("^file-v2-[a-f0-9-]{36}$")
    private val BLOB_ID = Regex("^[0-9a-f]{64}$")
    private val MIME = Regex("^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,63}$")
    private val B64URL = Regex("^[A-Za-z0-9_-]*$")
    private const val MAX_SAFE_INTEGER = 9007199254740991.0 // JS Number.MAX_SAFE_INTEGER

    /** 설명자. `key`·`nonce` 는 비밀 — `toString` 에 넣지 않는다(로그 유출 방지). */
    class Descriptor(
        val blob: String,
        val size: Long,
        val key: ByteArray,
        val nonce: ByteArray,
        val mime: String?,
        val name: String?,
        val w: Long?,
        val h: Long?,
    ) {
        override fun toString() = "FileV2.Descriptor(blob=${blob.take(12)}…, size=$size)"
    }

    /** 거부 이유는 고정된 짧은 코드뿐이다(보낸 쪽 값·키 이름을 담지 않는다 — 로그에 그대로 남겨도 된다). */
    class Rejected(val reason: String) : Exception("file-v2 descriptor rejected: $reason")

    /** 바깥 client_id 가 정규형 `file-v2-<uuid>` 인가(표시 힌트일 뿐 인증 정보가 아니다 — FILE-V2.md §1). */
    fun isClientId(clientId: String): Boolean = CLIENT_ID.matches(clientId)

    /** MLS 평문(UTF-8 바이트)을 설명자로 엄격 검증한다. 하나라도 어긋나면 [Rejected]. */
    fun parseDescriptor(plaintext: ByteArray): Descriptor {
        if (plaintext.size > MAX_DESCRIPTOR_BYTES) reject("too large")
        val text = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(plaintext)).toString()
        } catch (_: CharacterCodingException) {
            reject("not utf-8")
        }
        val raw = try {
            StrictJson(text).parseDocument()
        } catch (_: StrictJson.Malformed) {
            reject("not json")
        }
        if (raw !is Map<*, *>) reject("not an object")
        for (k in raw.keys) if (k !in ALLOWED) reject("unknown key")
        for (k in REQUIRED) if (k !in raw) reject("missing ${k}")
        if (integer(raw["v"], VERSION.toLong(), VERSION.toLong()) == null) reject("version")
        val blob = (raw["blob"] as? String)?.takeIf { BLOB_ID.matches(it) } ?: reject("blob")
        val size = integer(raw["size"], 1, MAX_FILE_BYTES) ?: reject("size")
        val key = base64urlDecode(raw["key"])?.takeIf { it.size == KEY_BYTES } ?: reject("key")
        val nonce = base64urlDecode(raw["nonce"])?.takeIf { it.size == NONCE_BYTES } ?: reject("nonce")
        val mime = if ("mime" in raw) {
            (raw["mime"] as? String)?.takeIf { it.length <= 100 && MIME.matches(it) } ?: reject("mime")
        } else null
        val name = if ("name" in raw) {
            (raw["name"] as? String)?.takeIf { validName(it) } ?: reject("name")
        } else null
        val w = if ("w" in raw) integer(raw["w"], 1, MAX_DIMENSION) ?: reject("w") else null
        val h = if ("h" in raw) integer(raw["h"], 1, MAX_DIMENSION) ?: reject("h") else null
        return Descriptor(blob, size, key, nonce, mime, name, w, h)
    }

    /** base64url(RFC 4648 §5, 패딩 없음, **정규형** — 다시 인코딩하면 같은 문자열). 아니면 null. */
    fun base64urlDecode(value: Any?): ByteArray? {
        val text = value as? String ?: return null
        if (!B64URL.matches(text) || text.length % 4 == 1) return null
        val bytes = try { Base64.getUrlDecoder().decode(text) } catch (_: IllegalArgumentException) { return null }
        return bytes.takeIf { Base64.getUrlEncoder().withoutPadding().encodeToString(it) == text }
    }

    /** JS `Number.isSafeInteger(x) && lo <= x && x <= hi` 와 같다(`2.0`·`2e0` 도 2). 숫자가 아니면 null. */
    private fun integer(value: Any?, lo: Long, hi: Long): Long? {
        val d = (value as? StrictJson.Num)?.value ?: return null
        if (!d.isFinite() || d != Math.floor(d) || Math.abs(d) > MAX_SAFE_INTEGER) return null
        val n = d.toLong()
        return n.takeIf { it in lo..hi }
    }

    /** 1~255 코드 포인트(웹 `[...name].length`), 빈 문자열·제어 문자(U+0000–001F, U+007F–009F) 없음. */
    private fun validName(name: String): Boolean =
        name.isNotEmpty() && name.codePointCount(0, name.length) <= 255 && name.none { it <= '\u001f' || it in '\u007f'..'\u009f' }

    private fun reject(reason: String): Nothing = throw Rejected(reason)

    // ---- 수신 분류 ----

    /** `messages` 표에 넣을 한 행의 kind · body · attachment. */
    class Row(val kind: String, val body: String, val attachment: ByteArray?)

    /**
     * 복호화한 application 메시지 하나를 저장 행으로 바꾼다(DeviceHub `onMessage`).
     * - `file-v1-…` → 첨부(평문 = 파일 바이트, 기존 동작).
     * - `file-v2-…` → 설명자 검증 성공이면 `file-v2`(body 는 자리 표시, attachment = 검증한 설명자 바이트 — 이력에는 설명자만, §4-2),
     *   실패면 `undecryptable`(평문은 저장하지 않는다). client_id 가 `file-v2-` 로 시작하지만 정규형이 아니어도 글로 보이지 않게
     *   `undecryptable` 로 둔다(설명자에 키가 있을 수 있으므로 안전한 쪽으로 닫는다).
     * - 그 밖 → 글.
     */
    fun classify(clientId: String, plaintext: ByteArray): Row {
        if (clientId.startsWith("file-v1-")) {
            return Row(MessageSchema.KIND_ATTACHMENT, Strings.attachmentPlaceholder(plaintext.size.toLong()), plaintext)
        }
        if (clientId.startsWith(CLIENT_PREFIX)) {
            if (!isClientId(clientId)) return Row(MessageSchema.KIND_UNDECRYPTABLE, Strings.fileV2Invalid, null)
            return try {
                val d = parseDescriptor(plaintext)
                Row(MessageSchema.KIND_FILE_V2, Strings.attachmentPlaceholder(d.size), plaintext.copyOf())
            } catch (_: Rejected) {
                Row(MessageSchema.KIND_UNDECRYPTABLE, Strings.fileV2Invalid, null)
            }
        }
        return Row(MessageSchema.KIND_TEXT, String(plaintext, Charsets.UTF_8), null)
    }
}

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
