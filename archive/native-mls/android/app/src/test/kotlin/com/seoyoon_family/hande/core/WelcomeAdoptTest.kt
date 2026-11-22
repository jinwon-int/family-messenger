// `WelcomeAdopt` 고정(#616): 지나가고도 참여하지 못한 Welcome 만, Welcome 하나에 한 번 다시 받아들인다(해 본 seq 는 기기에 저장).
// android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`).
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.core.WelcomeAdopt.Decision
import kotlin.test.Test
import kotlin.test.assertEquals

class WelcomeAdoptTest {
    private fun decide(
        known: Boolean = true, joined: Boolean = false, halted: Boolean = false, cursor: Long? = 120, welcomeSeq: Long = 100, retriedSeq: Long? = null,
    ) = WelcomeAdopt.decide(known, joined, halted, cursor, welcomeSeq, retriedSeq)

    @Test fun anUnknownRoomIsAdopted() {
        assertEquals(Decision.ADOPT, decide(known = false, cursor = null))
        // 모르는 방이면 다른 값은 보지 않는다.
        assertEquals(Decision.ADOPT, decide(known = false, joined = true, halted = true, cursor = 5, retriedSeq = 100))
    }

    @Test fun aJoinedOrHaltedRoomIsLeftAlone() {
        assertEquals(Decision.SKIP, decide(joined = true))
        assertEquals(Decision.SKIP, decide(halted = true))
    }

    @Test fun aRoomWhosePollHasNotReachedTheWelcomeIsLeftToItsOwnPoll() {
        // 막 받아들인 방: 커서가 Welcome 바로 앞(seq - 1).
        assertEquals(Decision.SKIP, decide(cursor = 99))
        assertEquals(Decision.SKIP, decide(cursor = 0))
        // 위치를 읽지 못했으면 건드리지 않는다.
        assertEquals(Decision.SKIP, decide(cursor = null))
    }

    @Test fun aWelcomeReadPastWithoutJoiningIsReadoptedOnce() {
        // 커서가 Welcome 에 닿았거나 지나갔는데 참여하지 못했다.
        assertEquals(Decision.READOPT, decide(cursor = 100))
        assertEquals(Decision.READOPT, decide(cursor = 5_000))
        // 같은 Welcome 을 이미 다시 해 봤으면(저장된 기록) 되풀이하지 않는다.
        assertEquals(Decision.SKIP, decide(cursor = 5_000, retriedSeq = 100))
    }

    @Test fun aNewerWelcomeAfterAReinviteIsTriedAgain() {
        // 내보냈다가 다시 초대하면 Welcome seq 가 커진다 — 앞선 시도와 상관없이 한 번 더.
        assertEquals(Decision.READOPT, decide(cursor = 5_010, welcomeSeq = 5_003, retriedSeq = 100))
        assertEquals(Decision.SKIP, decide(cursor = 5_010, welcomeSeq = 5_003, retriedSeq = 5_003))
    }

    @Test fun retriedRecordsRoundTripAndSurviveARestart() {
        val retried = mapOf("room-b" to 1_022L, "agent-room" to 7_919L)
        val text = WelcomeAdopt.encodeRetried(retried)
        assertEquals("agent-room|7919\nroom-b|1022", text) // 방 이름 순 — 같은 내용이면 같은 글
        assertEquals(retried, WelcomeAdopt.decodeRetried(text))
        // 재시작 뒤: 저장된 기록이 같은 Welcome 의 다시 받아들이기를 막는다.
        val restored = WelcomeAdopt.decodeRetried(text)
        assertEquals(Decision.SKIP, decide(cursor = 9_000, welcomeSeq = 1_022, retriedSeq = restored["room-b"]))
        assertEquals(Decision.READOPT, decide(cursor = 9_000, welcomeSeq = 2_064, retriedSeq = restored["room-b"]))
    }

    @Test fun decodeToleratesMissingAndMalformedText() {
        assertEquals(emptyMap<String, Long>(), WelcomeAdopt.decodeRetried(null))
        assertEquals(emptyMap<String, Long>(), WelcomeAdopt.decodeRetried(""))
        assertEquals("", WelcomeAdopt.encodeRetried(emptyMap()))
        // 모양이 어긋난 줄·숫자가 아닌 seq·음수·빈 방 이름은 버리고, 같은 방이 두 번이면 큰 값.
        val text = "room-b|10\nbroken\n|5\nroom-c|x\nroom-d|-1\nroom-b|12\n\nroom-e|0"
        assertEquals(mapOf("room-b" to 12L, "room-e" to 0L), WelcomeAdopt.decodeRetried(text))
    }

    @Test fun recordsOfJoinedOrVanishedRoomsAreForgotten() {
        val retried = mapOf("room-b" to 10L, "room-c" to 20L, "room-d" to 30L)
        // room-b 는 아직 참여하지 못했다 — 남긴다. room-c(참여함)·room-d(없어짐)는 지운다.
        assertEquals(mapOf("room-b" to 10L), WelcomeAdopt.pruneRetried(retried, waiting = setOf("room-b", "room-z")))
        assertEquals(emptyMap<String, Long>(), WelcomeAdopt.pruneRetried(retried, waiting = emptySet()))
    }
}
