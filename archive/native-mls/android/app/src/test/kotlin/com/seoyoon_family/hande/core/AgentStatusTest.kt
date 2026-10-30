// status-v1(#560) 임시 말풍선 판정 고정 — 웹 `status-v1.test.mjs` 와 같은 경우들. android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AgentStatusTest {
    private val now = 1_700_000_000_000L

    @Test fun statusClientIdShapeOnly() {
        assertTrue(FileV2.isStatusClientId("status-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2"))
        assertFalse(FileV2.isStatusClientId("status-report"))
        assertNull(FileV2.classify("status-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2", "⏳ x".toByteArray()), "status 는 저장하지 않는다")
    }

    @Test fun oneLinePerSenderUpdatedInPlaceOlderIgnored() {
        val b = AgentStatusBoard()
        assertTrue(b.apply("dungae-bot", "⏳ Working — 5s", 10, now))
        assertTrue(b.apply("dungae-bot", "⏳ Working — 10s | Bash: ls", 11, now))
        assertFalse(b.apply("dungae-bot", "⏳ Working — 10s | Bash: ls", 12, now), "같은 글 → 다시 그릴 것 없음")
        assertFalse(b.apply("dungae-bot", "⏳ old", 9, now), "옛 status 는 새 것을 덮지 않는다")
        b.apply("seoseo-bot", "⏳ Working — 5s", 13, now)
        assertEquals(listOf(StatusUi("dungae-bot", "⏳ Working — 10s | Bash: ls"), StatusUi("seoseo-bot", "⏳ Working — 5s")), b.visible(now))
        assertEquals("⏳ Working — 5s", b.listLine(now), "목록에는 가장 최근 줄")
    }

    @Test fun replyClearsOnlyThatSenderAndLateStatusNeverReappears() {
        val b = AgentStatusBoard()
        b.apply("dungae-bot", "⏳ a", 10, now)
        b.apply("seoseo-bot", "⏳ b", 11, now)
        assertTrue(b.clear("dungae-bot", 12))
        assertEquals(listOf("seoseo-bot"), b.visible(now).map { it.sender })
        assertTrue(b.clear("seoseo-bot", 20))
        assertFalse(b.apply("seoseo-bot", "⏳ late", 19, now), "답(seq 20)보다 앞선 status 는 다시 뜨지 않는다")
        assertNull(b.listLine(now))
        assertTrue(b.apply("seoseo-bot", "⏳ next turn", 21, now))
    }

    @Test fun expiresAfterFiveMinutesWithoutUpdate() {
        val b = AgentStatusBoard()
        b.apply("dungae-bot", "⏳ a", 1, now)
        assertEquals(1, b.visible(now + AgentStatusBoard.TTL_MS).size)
        assertEquals(0, b.visible(now + AgentStatusBoard.TTL_MS + 1).size)
        assertNull(b.listLine(now + AgentStatusBoard.TTL_MS + 1))
    }

    @Test fun blankIgnoredLongBounded() {
        val b = AgentStatusBoard()
        assertFalse(b.apply("dungae-bot", "   ", 1, now))
        assertFalse(b.apply("", "⏳", 1, now))
        b.apply("dungae-bot", "⏳ " + "x".repeat(5000), 2, now)
        assertEquals(500, b.visible(now).single().text.length)
    }
}
