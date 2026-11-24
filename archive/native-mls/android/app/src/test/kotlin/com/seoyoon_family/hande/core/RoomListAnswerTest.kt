// #870(AGENT-CHOICES-V1 §7) 방 목록 「답변 필요」 — 웹 roomAnswerNeeded · iOS AgentChoices.roomAnswer 와 같은 공유 벡터 `roomList`.
package com.seoyoon_family.hande.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

class RoomListAnswerTest {
    private val fixture: Map<*, *> by lazy {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val f = File(dir, "archive/native-mls/tests/fixtures/agent-choices-vectors.json")
            if (f.isFile) return@lazy MiniJson(f.readText(Charsets.UTF_8)).parse() as Map<*, *>
            dir = dir.parentFile
        }
        fail("agent-choices-vectors.json not found above ${File(".").absolutePath}")
    }

    /**
     * 웹 벡터 entry({kind, body, isAgent, isService, isMe}) → MessageUi. Android 타임라인(`messages`)은 저장된 글·첨부만이라
     * 시스템 줄(`kind: system`)은 애초에 없다 → 건너뛴다(규격 §2 「저장된 메시지」와 같은 뜻).
     */
    private fun toMessages(entries: List<*>): List<MessageUi> = entries.mapIndexedNotNull { i, raw ->
        raw as Map<*, *>
        val kind = raw["kind"] as String
        if (kind == "system") return@mapIndexedNotNull null
        val mine = raw["isMe"] == true
        val sender = when {
            mine -> "owner-iphone-27a879"
            raw["isAgent"] == true -> "bot-gongmyoung"
            raw["isService"] == true -> "fleet-bot"
            else -> "jungin-iphone-1b89e3"
        }
        MessageUi(seq = i + 1L, sender = sender, text = raw["body"] as String, mine = mine, attachment = kind == "attachment")
    }

    @Test fun roomListVectors() {
        val cases = fixture["roomList"] as List<*>
        assertTrue(cases.size >= 12, "roomList vectors loaded")
        for (c in cases) {
            c as Map<*, *>
            val name = c["name"] as String
            val got = AgentChoices.roomAnswer(toMessages(c["entries"] as List<*>))
            val expected = c["expected"] as Map<*, *>?
            if (expected == null) {
                assertNull(got, "[$name]")
                continue
            }
            val mode = if (expected["mode"] == "one") AgentChoices.Mode.ONE else AgentChoices.Mode.MANY
            val want = AgentChoices.RoomAnswer(mode, (expected["count"] as Long).toInt(), (expected["number"] as Long).toInt(), expected["label"] as String)
            assertEquals(want, got, "[$name]")
        }
    }

    private val answer = AgentChoices.RoomAnswer(AgentChoices.Mode.ONE, 3, 1, "(권장) A안")

    @Test fun answerComesBeforeWaitingLine() {
        assertEquals(RoomListSlot.Kind.ANSWER, RoomListSlot.kind(halted = false, joined = true, working = "⏳ 대기 중 · PR CI", answer = answer))
        assertEquals(RoomListSlot.Kind.WORKING, RoomListSlot.kind(halted = false, joined = true, working = "⏳ Working — 10s", answer = null))
        assertEquals(RoomListSlot.Kind.PREVIEW, RoomListSlot.kind(halted = false, joined = true, working = null, answer = null))
    }

    @Test fun haltedAndNotJoinedWin() {
        assertEquals(RoomListSlot.Kind.HALTED, RoomListSlot.kind(halted = true, joined = true, working = "⏳", answer = answer))
        assertEquals(RoomListSlot.Kind.NOT_JOINED, RoomListSlot.kind(halted = false, joined = false, working = "⏳", answer = answer))
    }
}
