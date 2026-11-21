// `WelcomeAdopt` 고정(#616): 지나가고도 참여하지 못한 Welcome 만, 실행 한 번에 한 번 다시 받아들인다.
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

    @Test fun aWelcomeReadPastWithoutJoiningIsReadoptedOncePerRun() {
        // 커서가 Welcome 에 닿았거나 지나갔는데 참여하지 못했다.
        assertEquals(Decision.READOPT, decide(cursor = 100))
        assertEquals(Decision.READOPT, decide(cursor = 5_000))
        // 이번 실행에서 같은 Welcome 을 이미 다시 해 봤으면 되풀이하지 않는다.
        assertEquals(Decision.SKIP, decide(cursor = 5_000, retriedSeq = 100))
    }

    @Test fun aNewerWelcomeAfterAReinviteIsTriedAgain() {
        // 내보냈다가 다시 초대하면 Welcome seq 가 커진다 — 앞선 시도와 상관없이 한 번 더.
        assertEquals(Decision.READOPT, decide(cursor = 5_010, welcomeSeq = 5_003, retriedSeq = 100))
        assertEquals(Decision.SKIP, decide(cursor = 5_010, welcomeSeq = 5_003, retriedSeq = 5_003))
    }
}
