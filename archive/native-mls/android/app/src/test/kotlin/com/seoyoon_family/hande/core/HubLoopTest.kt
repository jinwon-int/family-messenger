// `HubLoop` 수명 고정(#766 A): 루프는 허브 scope 에서 돌고, `start` 를 부른 화면 scope 가 취소돼도 살아 있다.
// android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`). 가상 시간 라이브러리 없이 실제 디스패처 + 넉넉한 타임아웃으로 기다린다.
package com.seoyoon_family.hande.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class HubLoopTest {
    private val waitMs = 5_000L

    private fun newScope() = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** 회귀(#766 A): 옛 화면의 scope 가 취소되고 새 화면이 다시 `start` 를 불러도 루프는 한 개가 계속 돈다. */
    @Test fun loopOutlivesTheScreenScopeThatStartedIt() = runBlocking<Unit> {
        val hubScope = newScope()
        val loop = HubLoop(hubScope)
        val ticks = Channel<Int>(Channel.UNLIMITED)
        val blocks = AtomicInteger(0)
        val body: suspend CoroutineScope.() -> Unit = {
            blocks.incrementAndGet()
            var n = 0
            while (isActive) { ticks.send(n++); delay(2) }
        }
        try {
            // 첫 화면(Activity)이 자기 scope 의 코루틴 안에서 시작한다.
            val firstScreen = newScope()
            val startedByFirst = CompletableDeferred<Boolean>()
            firstScreen.launch { startedByFirst.complete(loop.start(body)) }
            assertTrue(withTimeout(waitMs) { startedByFirst.await() })
            withTimeout(waitMs) { ticks.receive() }

            // 회전·다크모드 전환: 옛 화면 scope 취소 → 새 화면이 다시 start.
            firstScreen.cancel()
            assertFalse(loop.start(body), "이미 도는 루프가 있으면 두 번째 start 는 아무것도 띄우지 않는다")
            assertTrue(loop.started)

            // 취소 전에 쌓인 틱을 비운 뒤에도 새 틱이 계속 온다 = 루프가 살아 있다.
            // (루프가 화면 scope 에 묶여 있었다면 취소 경합으로 많아야 한 개가 더 온다 — 그래서 세 개를 기다린다.)
            while (ticks.tryReceive().isSuccess) { /* 비우기 */ }
            withTimeout(waitMs) { repeat(3) { ticks.receive() } }
            assertEquals(1, blocks.get(), "루프 블록은 한 번만 시작한다")
        } finally {
            hubScope.cancel()
        }
    }

    /** `stop` 은 도는 루프를 취소하고, 그 뒤 `start` 는 새 루프를 띄운다(이 기기 지우기 → 처음 설정). */
    @Test fun stopCancelsAndAllowsARestart() = runBlocking<Unit> {
        val hubScope = newScope()
        val loop = HubLoop(hubScope)
        try {
            assertFalse(loop.started)
            val running = CompletableDeferred<Unit>()
            val cancelled = CompletableDeferred<Unit>()
            assertTrue(loop.start {
                running.complete(Unit)
                try { awaitCancellation() } finally { cancelled.complete(Unit) }
            })
            withTimeout(waitMs) { running.await() }

            loop.stop()
            withTimeout(waitMs) { cancelled.await() }
            assertFalse(loop.started)

            val again = CompletableDeferred<Unit>()
            assertTrue(loop.start { again.complete(Unit) })
            withTimeout(waitMs) { again.await() }
        } finally {
            hubScope.cancel()
        }
    }

    /** 블록이 스스로 끝나도(시작 실패) 「시작함」으로 남는다 — 화면이 다시 그려질 때마다 boot 를 되풀이하지 않는다. */
    @Test fun finishedLoopStaysStartedUntilStopped() = runBlocking<Unit> {
        val hubScope = newScope()
        val loop = HubLoop(hubScope)
        try {
            val done = CompletableDeferred<Unit>()
            assertTrue(loop.start { done.complete(Unit) })
            withTimeout(waitMs) { done.await() }
            delay(20)
            assertTrue(loop.started)
            assertFalse(loop.start { error("끝난 루프를 다시 띄우면 안 된다") })
        } finally {
            hubScope.cancel()
        }
    }
}
