// alert-refs-v1(archive/native-mls/ALERT-REFS-V1.md, 오너 요청 2026-11-07) — 플릿 알림의 `#번호` 를 눌러 원래 알림으로 이동.
// 판정은 세 앱 공통(공유 벡터 tests/fixtures/alert-refs-vectors.json). 위치는 Kotlin String(UTF-16) index, 라벨 길이는 코드 포인트.
package com.seoyoon_family.hande.core

object AlertRefs {
    /** 플릿 알림 봇 actor(기기 `fleet-bot`). 링크는 이 봇의 글에만. */
    const val FLEET_ACTOR = "fleet"

    /** 참조 하나: 번호 + 글 안 위치 [start, end)(UTF-16, `#` 포함). */
    data class Ref(val id: String, val start: Int, val end: Int)
    data class Parsed(val self: String?, val refs: List<Ref>)

    private fun idChar(c: Char) = c in '0'..'9' || c in 'a'..'z'
    private fun word(c: Char) = c in '0'..'9' || c in 'a'..'z' || c in 'A'..'Z' || c == '_'

    fun isFleetDevice(device: String): Boolean = device.substringBefore('-') == FLEET_ACTOR

    /** s[i] 에서 시작하는 번호(§1 경계 규칙)면 6자, 아니면 null. */
    private fun idAt(s: String, i: Int): String? {
        if (i >= s.length || s[i] != '#') return null
        if (i > 0 && (word(s[i - 1]) || s[i - 1] == '#')) return null
        if (i + 7 > s.length) return null
        val id = s.substring(i + 1, i + 7)
        if (!id.all(::idChar)) return null
        if (i + 7 < s.length && word(s[i + 7])) return null
        return id
    }

    /** `[라벨] ` 접두(라벨 1~40 코드 포인트, `]`·줄바꿈 없음)의 길이(UTF-16), 없으면 0. */
    private fun labelLength(s: String): Int {
        if (!s.startsWith("[")) return 0
        val close = s.indexOfAny(charArrayOf(']', '\n'), 1)
        if (close < 0 || s[close] != ']' || close + 1 >= s.length || s[close + 1] != ' ') return 0
        val points = s.codePointCount(1, close)
        return if (points in 1..40) close + 2 else 0
    }

    fun parse(text: String): Parsed {
        if (text.isEmpty()) return Parsed(null, emptyList())
        val at = labelLength(text)
        val own = idAt(text, at)
        val self = if (own != null && (at + 7 == text.length || text[at + 7] == ' ' || text[at + 7] == '\n')) own else null
        val refs = mutableListOf<Ref>()
        var i = 0
        while (i < text.length) {
            if (self != null && i == at) { i += 7; continue }
            val id = idAt(text, i)
            if (id != null && id != self) { refs += Ref(id, i, i + 7); i += 7; continue }
            i += 1
        }
        return Parsed(self, refs)
    }

    /** 이동 대상: messages(타임라인 순) 중 플릿 알림 봇 글로 자기 번호가 id 인 가장 최근 것의 index. 누른 글(fromIndex)은 뺀다. 없으면 -1. */
    fun targetIndex(messages: List<MessageUi>, id: String, fromIndex: Int = -1): Int {
        for (i in messages.indices.reversed()) {
            val m = messages[i]
            if (i == fromIndex || m.attachment || !isFleetDevice(m.sender)) continue
            if (parse(m.text).self == id) return i
        }
        return -1
    }
}
