// `WatchPlan` 고정(#766 E): watch 가 알려 준 바뀐 방만 poll, 전 방 훑기는 첫 틱·watch 못 씀·60 s 안전망일 때만.
// android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`).
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.core.WatchPlan.Room
import com.seoyoon_family.hande.core.WatchPlan.Sweep
import com.seoyoon_family.hande.core.WatchPlan.Wake
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class WatchPlanTest {
    private val rooms = listOf(Room("a", halted = false, synced = true), Room("b", halted = false, synced = true), Room("c", halted = false, synced = true))
    private val all = setOf("a", "b", "c")
    private val t0 = 1_000_000L

    private fun watched(changed: List<String>, refused: List<String> = emptyList(), watched: Set<String> = all) = Wake.Watched(watched, changed, refused)

    @Test fun firstTickIsAFullSweep() {
        assertEquals(Sweep.Full, WatchPlan.plan(rooms, null, null, t0))
        // 대기 결과가 있어도 전 방 훑기를 한 적이 없으면(준비 단계로 돌아옴 등) 전 방.
        assertEquals(Sweep.Full, WatchPlan.plan(rooms, watched(listOf("a")), null, t0))
    }

    @Test fun watchedChangesPollOnlyTheChangedRooms() {
        assertEquals(Sweep.Only(listOf("b")), WatchPlan.plan(rooms, watched(listOf("b")), t0, t0 + 5_000))
        // 변화 없이 대기만 끝났으면 poll 할 방이 없다.
        assertEquals(Sweep.Only(emptyList()), WatchPlan.plan(rooms, watched(emptyList()), t0, t0 + 5_000))
        // 모르는 방 이름(이미 없어진 방)은 무시.
        assertEquals(Sweep.Only(listOf("a")), WatchPlan.plan(rooms, watched(listOf("a", "zzz")), t0, t0 + 5_000))
    }

    @Test fun unsupportedOrFailedWatchFallsBackToAFullSweep() {
        assertEquals(Sweep.Full, WatchPlan.plan(rooms, Wake.Unknown, t0, t0 + 5_000))
    }

    @Test fun safetyIntervalElapsedForcesAFullSweep() {
        assertEquals(Sweep.Only(listOf("a")), WatchPlan.plan(rooms, watched(listOf("a")), t0, t0 + WatchPlan.SAFETY_SWEEP_MS - 1))
        assertEquals(Sweep.Full, WatchPlan.plan(rooms, watched(listOf("a")), t0, t0 + WatchPlan.SAFETY_SWEEP_MS))
        // 시계가 거꾸로 가면 모호 — 전 방.
        assertEquals(Sweep.Full, WatchPlan.plan(rooms, watched(listOf("a")), t0, t0 - 1))
    }

    @Test fun refusedRoomsArePolledSoTheRelayVerdictLands() {
        // no_such_room·room_closed 는 릴레이가 기다리지 않는다 — poll 이 정지 판정을 받게 한다.
        assertEquals(Sweep.Only(listOf("a", "c")), WatchPlan.plan(rooms, watched(listOf("a"), refused = listOf("c")), t0, t0 + 5_000))
    }

    @Test fun haltedRoomsAreExcludedFromChangedOnlyPolls() {
        val withHalted = rooms.map { if (it.name == "b") it.copy(halted = true, synced = false) else it }
        assertEquals(Sweep.Only(listOf("a")), WatchPlan.plan(withHalted, watched(listOf("a", "b"), refused = listOf("b")), t0, t0 + 5_000))
    }

    @Test fun unwatchedAndFailedRoomsAreAlwaysPolled() {
        // watch 에 싣지 않은 방(64개 상한 너머·커서를 못 읽음·막 받아들인 방)은 변화를 알 수 없다 → 매 틱.
        assertEquals(Sweep.Only(listOf("c")), WatchPlan.plan(rooms, watched(emptyList(), watched = setOf("a", "b")), t0, t0 + 5_000))
        // 마지막 poll 이 실패한 방은 다음 틱에 다시.
        val failed = rooms.map { if (it.name == "a") it.copy(synced = false) else it }
        assertEquals(Sweep.Only(listOf("a", "b")), WatchPlan.plan(failed, watched(listOf("b")), t0, t0 + 5_000))
    }

    @Test fun lobbyWorkRunsFirstThenOnItsOwnCadence() {
        assertTrue(WatchPlan.auxDue(null, t0))
        assertFalse(WatchPlan.auxDue(t0, t0 + WatchPlan.AUX_EVERY_MS - 1))
        assertTrue(WatchPlan.auxDue(t0, t0 + WatchPlan.AUX_EVERY_MS))
        assertTrue(WatchPlan.auxDue(t0, t0 - 1))
    }
}
