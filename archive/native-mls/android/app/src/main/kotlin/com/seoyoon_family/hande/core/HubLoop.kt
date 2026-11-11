// 허브 poll 루프의 수명(#766 A). 루프는 **허브(프로세스) 수명 scope** 에서 한 번만 돈다 — 부른 쪽(화면)의 scope 와 무관하다.
// 전에는 `DeviceHub.start(scope)` 가 Activity `lifecycleScope` 에서 루프를 띄웠다. 회전·다크모드 전환·시스템의 Activity 회수로
// 그 scope 가 취소되면 루프도 취소되는데, 허브는 「이미 시작함」으로 기억해 새 Activity 의 `start` 를 무시했다 → 프로세스를 다시
// 시작할 때까지 새 글이 오지 않았다(보내기는 됨).
// android.* 없음 — JVM 단위 테스트(`HubLoopTest`)로 돈다.
package com.seoyoon_family.hande.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class HubLoop(private val scope: CoroutineScope) {
    private var job: Job? = null

    /** 시작했는가(끝났어도 참 — 시작 실패 뒤 저절로 다시 돌지 않는다. 다시 돌리려면 [stop] 뒤 [start]). */
    val started: Boolean
        @Synchronized get() = job != null

    /** 아직 시작하지 않았으면 허브 scope 에서 [block] 을 띄우고 참. 이미 시작했으면 아무것도 하지 않고 거짓. */
    @Synchronized
    fun start(block: suspend CoroutineScope.() -> Unit): Boolean {
        if (job != null) return false
        job = scope.launch(block = block)
        return true
    }

    /** 루프를 취소하고 「시작 안 함」으로 되돌린다(이 기기 지우기 뒤 처음 설정에서 다시 [start]). */
    @Synchronized
    fun stop() {
        job?.cancel()
        job = null
    }
}
