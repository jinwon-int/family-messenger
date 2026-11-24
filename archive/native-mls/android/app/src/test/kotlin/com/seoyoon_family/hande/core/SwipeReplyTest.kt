// 말풍선 밀어서 답장 판정(#880) — iOS FamilyMLSCoreTests `SwipeReplyTests` 이식(Android 해당분: 축 고정 · 문턱 · 저항 · 놓을 때 판정).
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SwipeReplyTest {
    @Test
    fun axisWaitsUntilLockDistance() {
        assertNull(SwipeReply.axis(-5.0, 0.0), "too small to decide yet")
        assertNull(SwipeReply.axis(-8.0, -8.0), "11.3dp < 12")
        assertEquals(SwipeReply.Axis.REPLY, SwipeReply.axis(-12.0, 0.0), "exactly the lock distance")
    }

    @Test
    fun leftwardHorizontalDragLocksToReply() {
        assertEquals(SwipeReply.Axis.REPLY, SwipeReply.axis(-20.0, 5.0))
        assertEquals(SwipeReply.Axis.REPLY, SwipeReply.axis(-16.0, -10.0), "16 > 10 × 1.5")
    }

    @Test
    fun rightwardVerticalOrDiagonalDragIsIgnored() {
        assertEquals(SwipeReply.Axis.IGNORE, SwipeReply.axis(20.0, 0.0), "rightward never replies")
        assertEquals(SwipeReply.Axis.IGNORE, SwipeReply.axis(-3.0, 20.0), "timeline scroll")
        assertEquals(SwipeReply.Axis.IGNORE, SwipeReply.axis(-15.0, -10.0), "15 is not > 10 × 1.5")
    }

    @Test
    fun offsetFollowsFingerThenResistsAndCaps() {
        assertEquals(0.0, SwipeReply.offset(30.0), "rightward never moves the bubble")
        assertEquals(0.0, SwipeReply.offset(0.0))
        assertEquals(-40.0, SwipeReply.offset(-40.0))
        assertEquals(-60.0, SwipeReply.offset(-60.0), "exactly the trigger distance")
        assertEquals(-72.0, SwipeReply.offset(-100.0), 1e-9, "60 + 40 × 0.3")
        assertEquals(-SwipeReply.MAX_OFFSET, SwipeReply.offset(-500.0), "capped")
    }

    @Test
    fun shouldReplyNeedsTriggerDistanceAndDominance() {
        assertTrue(SwipeReply.shouldReply(-60.0, 0.0), "exactly the trigger distance")
        assertTrue(SwipeReply.shouldReply(-120.0, 30.0))
        assertFalse(SwipeReply.shouldReply(-59.9, 0.0), "short")
        assertFalse(SwipeReply.shouldReply(120.0, 0.0), "rightward")
        // #745: 축은 시작 때 정했다 — 끝에서는 엄지 궤적이 위로 휜 것(약 53°까지)도 답장.
        assertTrue(SwipeReply.shouldReply(-90.0, 60.0), "thumb arc toward the top: 90 ≥ 60 × 0.75")
        assertTrue(SwipeReply.shouldReply(-75.0, -100.0), "75 ≥ 100 × 0.75 (boundary)")
        assertFalse(SwipeReply.shouldReply(-74.0, -100.0), "mostly vertical at release")
    }

    @Test
    fun rightwardDragNeverReplies() {
        var dx = 0.0
        while (dx <= 300.0) {
            assertFalse(SwipeReply.shouldReply(dx, 0.0), "dx=$dx")
            assertEquals(0.0, SwipeReply.offset(dx), "dx=$dx")
            dx += 10.0
        }
    }
}
