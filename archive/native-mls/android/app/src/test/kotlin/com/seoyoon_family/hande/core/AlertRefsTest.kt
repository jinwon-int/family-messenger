// alert-refs-v1 판정 고정 — 웹·iOS 와 같은 공유 벡터 `archive/native-mls/tests/fixtures/alert-refs-vectors.json`.
package com.seoyoon_family.hande.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

class AlertRefsTest {
    private val fixture: Map<*, *> by lazy {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val f = File(dir, "archive/native-mls/tests/fixtures/alert-refs-vectors.json")
            if (f.isFile) return@lazy MiniJson(f.readText(Charsets.UTF_8)).parse() as Map<*, *>
            dir = dir.parentFile
        }
        fail("alert-refs-vectors.json not found above ${File(".").absolutePath}")
    }

    @Test fun parseVectors() {
        val cases = fixture["parse"] as List<*>
        assertTrue(cases.size >= 10)
        for (c in cases) {
            c as Map<*, *>
            val name = c["name"] as String
            val text = c["text"] as String
            val got = AlertRefs.parse(text)
            assertEquals(c["self"] as String?, got.self, name)
            assertEquals((c["refs"] as List<*>).map { it as String }, got.refs.map { it.id }, name)
            for (r in got.refs) assertEquals("#${r.id}", text.substring(r.start, r.end), name)
        }
    }

    @Test fun targetIsTheLatestFleetAlertWithThatSelfId() {
        fun fleet(seq: Long, text: String) = MessageUi(seq, "fleet-bot", text, mine = false)
        val messages = listOf(
            fleet(1, "[서서] #6c9kzj 첫 알림"),
            MessageUi(2, "owner-iphone-1", "#6c9kzj 사람이 쓴 글", mine = true),
            MessageUi(3, "card-bot", "#6c9kzj 카드 봇", mine = false),
            fleet(4, "#69pgri ⏰ 재통지 1/3 #6c9kzj"),
        )
        assertEquals(0, AlertRefs.targetIndex(messages, "6c9kzj", fromIndex = 3))
        assertEquals(3, AlertRefs.targetIndex(messages, "69pgri"))
        assertEquals(-1, AlertRefs.targetIndex(messages, "69pgri", fromIndex = 3))
        assertEquals(-1, AlertRefs.targetIndex(messages, "zzzzzz"))
        assertEquals(4, AlertRefs.targetIndex(messages + fleet(5, "#6c9kzj 나중 글"), "6c9kzj", fromIndex = 3))
    }
}
