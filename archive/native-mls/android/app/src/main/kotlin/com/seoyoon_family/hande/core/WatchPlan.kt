// 틱이 무엇을 poll 할지(#766 E). `/v2/watch` 가 알려 준 바뀐 방만 poll 하고, 전 방 훑기는 안전망일 때만 한다 — 웹 `watch-loop.js`
// (바뀐 방만 즉시 sync, 방별 폴링은 SAFETY_POLL_MS 60 s 안전망)와 같은 규칙. 모호하면 전 방 훑기(지금까지의 동작)로 떨어진다.
// 로비 쪽 일(초대 Welcome · 승인 후보 · 빠진 방 재탐색)은 방 변화와 무관하므로 틱마다가 아니라 [AUX_EVERY_MS] 주기로(첫 틱은 바로).
// android.* 없음 — JVM 단위 테스트(`WatchPlanTest`)로 돈다.
package com.seoyoon_family.hande.core

object WatchPlan {
    /** 전 방 훑기 안전망 간격(웹 `SAFETY_POLL_MS`) — watch 가 어떤 이유로 놓쳐도 이 안에 맞춰진다. */
    const val SAFETY_SWEEP_MS = 60_000L
    /** `welcomes`·`discoverCandidates`·`rescanSiblings` 주기. */
    const val AUX_EVERY_MS = 15_000L

    /** 틱 사이 대기가 끝난 까닭 — 다음 틱의 입력. */
    sealed interface Wake {
        /**
         * watch 가 정상 응답했다. [watched] = 그 요청에 실은 방(여기 없는 방은 변화를 알 수 없다), [changed] = 바뀐 방,
         * [refused] = 릴레이가 기다리지 않은 방(`no_such_room`·`room_closed` — 릴레이 말대로 poll 로 처리한다).
         */
        data class Watched(val watched: Set<String>, val changed: List<String>, val refused: List<String>) : Wake

        /** watch 를 쓰지 못했다(준비 전·미지원·오류·고정 주기 대기) — 무엇이 바뀌었는지 모른다. */
        data object Unknown : Wake
    }

    /** 이 틱에 poll 할 방. */
    sealed interface Sweep {
        data object Full : Sweep
        data class Only(val rooms: List<String>) : Sweep
    }

    /** 방 하나의 판정 입력: [halted] = 정지된 방, [synced] = 마지막 poll 이 성공했나(실패한 방은 다음 틱에 다시). */
    data class Room(val name: String, val halted: Boolean, val synced: Boolean)

    /**
     * 전 방 훑기: 첫 틱([wake]·[lastFullAt] 이 null) · watch 를 못 썼을 때([Wake.Unknown]) · 마지막 전 방 훑기에서 [SAFETY_SWEEP_MS] 가
     * 지났을 때(시계가 거꾸로 가도). 그 밖에는 정지되지 않은 방 중 바뀐 방 · 거절된 방 · watch 에 싣지 않은 방 · 마지막 poll 이 실패한 방만.
     */
    fun plan(rooms: List<Room>, wake: Wake?, lastFullAt: Long?, now: Long): Sweep {
        if (wake !is Wake.Watched || lastFullAt == null) return Sweep.Full
        if (now < lastFullAt || now - lastFullAt >= SAFETY_SWEEP_MS) return Sweep.Full
        val hinted = HashSet<String>(wake.changed.size + wake.refused.size).apply { addAll(wake.changed); addAll(wake.refused) }
        return Sweep.Only(rooms.filter { r -> !r.halted && (r.name in hinted || r.name !in wake.watched || !r.synced) }.map { it.name })
    }

    /** 로비 쪽 일을 이 틱에 할 때인가: 처음([lastAt] null) · [AUX_EVERY_MS] 지남 · 시계가 거꾸로 감. */
    fun auxDue(lastAt: Long?, now: Long): Boolean = lastAt == null || now < lastAt || now - lastAt >= AUX_EVERY_MS
}
