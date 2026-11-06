// 대화 목록 순서 동기화(#715 room-order v1 클라이언트 규칙 1·2·4) — 가짜 전송·시계·저장으로 채택·시드·409·404·60초 간격·재전송을 고정한다.
// android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RoomOrderSyncTest {
    private class MemStore(order: List<String> = emptyList(), revision: Long = 0L, pending: Boolean = false) : RoomOrderSync.Store {
        override var roomOrder: List<String> = order
        override var roomOrderRevision: Long = revision
        override var roomOrderPending: Boolean = pending
    }

    private data class Call(val method: String, val url: String, val body: String?)

    /** 응답 대기열을 차례로 돌려준다. `null` = 응답 없음(연결 실패). 대기열이 비면 실패로 알린다. */
    private class FakeRelay {
        val calls = ArrayList<Call>()
        val replies = ArrayDeque<RoomOrderSync.Reply?>()
        /** 요청을 받는 순간 할 일(예: PUT 이 도는 사이 사용자가 또 옮김). */
        var onCall: ((Call) -> Unit)? = null

        fun reply(status: Int, body: String) { replies.addLast(RoomOrderSync.Reply(status, body.toByteArray(Charsets.UTF_8))) }
        fun noResponse() { replies.addLast(null) }

        fun send(method: String, url: String, body: ByteArray?): RoomOrderSync.Reply? {
            val call = Call(method, url, body?.toString(Charsets.UTF_8))
            calls += call
            onCall?.invoke(call)
            check(replies.isNotEmpty()) { "unexpected request $call" }
            return replies.removeFirst()
        }
    }

    private var clock = 1_000_000L
    private val relay = FakeRelay()
    private val changes = ArrayList<List<String>>()

    private fun engine(store: MemStore): RoomOrderSync =
        RoomOrderSync(store, relayUrl = { RELAY }, device = { DEVICE }, http = relay::send, now = { clock })
            .also { it.onChange = { order -> changes += order } }

    private fun snapshot(rooms: List<String>, revision: Long) =
        """{"rooms":${RoomOrder.encode(rooms)},"revision":$revision,"updated_at":1762400000}"""

    private fun conflict(rooms: List<String>, revision: Long) =
        """{"error":"revision_conflict","rooms":${RoomOrder.encode(rooms)},"revision":$revision,"updated_at":1762400000}"""

    // ---- 규칙 1: 불러올 때 GET ----

    @Test fun bootAdoptsServerOrderWhenRevisionPositive() {
        val store = MemStore(listOf("b", "a"), revision = 0L)
        val e = engine(store)
        assertTrue(e.isDue(), "시작하면 바로 묻는다")
        relay.reply(200, snapshot(listOf("c", "a"), 3))
        e.sync()
        assertEquals(listOf(Call("GET", "$RELAY/v2/me/room-order?device=$DEVICE", null)), relay.calls)
        assertEquals(listOf("c", "a"), e.order)
        assertEquals(listOf("c", "a"), store.roomOrder)
        assertEquals(3L, store.roomOrderRevision)
        assertFalse(store.roomOrderPending)
        assertEquals(listOf(listOf("c", "a")), changes, "다시 그린다")
        assertFalse(e.isDue(), "다 했으면 다음 계기까지 묻지 않는다")
    }

    @Test fun adoptingTheSameOrderDoesNotRedraw() {
        val store = MemStore(listOf("a", "b"), revision = 2L)
        val e = engine(store)
        relay.reply(200, snapshot(listOf("a", "b"), 2))
        e.sync()
        assertTrue(changes.isEmpty())
        assertEquals(2L, store.roomOrderRevision)
    }

    @Test fun firstDeviceSeedsLocalOrderWithBaseZero() {
        val store = MemStore(listOf("b", "a"))
        val e = engine(store)
        relay.reply(200, snapshot(emptyList(), 0))
        relay.reply(200, snapshot(listOf("b", "a"), 1))
        e.sync()
        assertEquals(2, relay.calls.size)
        assertEquals(Call("PUT", "$RELAY/v2/me/room-order", """{"device":"$DEVICE","rooms":["b","a"],"base_revision":0}"""), relay.calls[1])
        assertEquals(1L, store.roomOrderRevision)
        assertFalse(store.roomOrderPending)
        assertEquals(listOf("b", "a"), e.order)
    }

    @Test fun seedThatLosesTheRaceAdoptsTheServer() {
        val store = MemStore(listOf("b", "a"))
        val e = engine(store)
        relay.reply(200, snapshot(emptyList(), 0))
        relay.reply(409, conflict(listOf("a", "c", "b"), 1)) // 아이폰이 먼저 시드했다
        e.sync()
        assertEquals(listOf("a", "c", "b"), e.order)
        assertEquals(1L, store.roomOrderRevision)
        assertFalse(store.roomOrderPending)
        assertEquals(listOf(listOf("a", "c", "b")), changes)
    }

    @Test fun nothingToSeedWhenLocalIsEmpty() {
        val store = MemStore()
        val e = engine(store)
        relay.reply(200, snapshot(emptyList(), 0))
        e.sync()
        assertEquals(1, relay.calls.size, "PUT 없음")
        assertTrue(e.order.isEmpty())
        assertFalse(store.roomOrderPending)
    }

    @Test fun triggersAreAtLeastSixtySecondsApart() {
        val e = engine(MemStore())
        relay.reply(200, snapshot(emptyList(), 0))
        e.sync()
        e.request() // 전면 복귀 직후
        assertFalse(e.isDue())
        e.sync()
        assertEquals(1, relay.calls.size, "60초 안에는 다시 묻지 않는다")
        clock += RoomOrderSync.MIN_INTERVAL_MS
        assertTrue(e.isDue())
        relay.reply(200, snapshot(listOf("x"), 9))
        e.sync()
        assertEquals(2, relay.calls.size)
        assertEquals(listOf("x"), e.order)
    }

    @Test fun loginResetsTheIntervalAndAsksAtOnce() {
        val e = engine(MemStore())
        relay.reply(200, snapshot(emptyList(), 0))
        e.sync()
        e.resetSession()
        assertTrue(e.isDue(), "새 세션은 60초를 기다리지 않는다")
        relay.reply(200, snapshot(listOf("a"), 1))
        e.sync()
        assertEquals(listOf("a"), e.order)
    }

    @Test fun transientFailuresRetryOnTheNextCycle() {
        val store = MemStore(listOf("a"))
        val e = engine(store)
        relay.noResponse()
        e.sync()
        assertEquals(listOf("a"), store.roomOrder, "실패 동안 로컬 순서는 그대로")
        assertFalse(e.isDue(), "곧바로 다시 하지 않는다")
        clock += RoomOrderSync.MIN_INTERVAL_MS
        assertTrue(e.isDue(), "다음 주기(60초 뒤)에 다시")
        relay.reply(401, """{"error":"unauthorized"}""")
        e.sync()
        clock += RoomOrderSync.MIN_INTERVAL_MS
        assertTrue(e.isDue(), "401·5xx 도 다시")
        relay.reply(200, snapshot(listOf("b", "a"), 2))
        e.sync()
        assertEquals(listOf("b", "a"), e.order)
    }

    // ---- 규칙 4: 404 = 옛 릴레이 ----

    @Test fun oldRelayDisablesSyncForTheSession() {
        val store = MemStore(listOf("a", "b"))
        val e = engine(store)
        relay.reply(404, "404 page not found")
        e.sync()
        assertFalse(e.synced)
        clock += 10 * RoomOrderSync.MIN_INTERVAL_MS
        e.request()
        assertFalse(e.isDue(), "이 세션 동안 다시 묻지 않는다")
        e.move(listOf("b", "a"))
        e.push()
        assertEquals(1, relay.calls.size, "옮겨도 올리지 않는다")
        assertEquals(listOf("b", "a"), store.roomOrder, "로컬에는 저장")
        e.resetSession() // 다시 로그인
        assertTrue(e.synced)
        assertTrue(e.isDue())
    }

    // ---- 규칙 2: 사용자가 옮기면 PUT ----

    @Test fun userMovePutsWithLastSeenRevision() {
        val store = MemStore(listOf("a", "b", "c"), revision = 4L)
        val e = engine(store)
        relay.reply(200, snapshot(listOf("a", "b", "c"), 4))
        e.sync()
        val saved = e.move(listOf("b", "a", "c"))
        assertEquals(listOf("b", "a", "c"), saved)
        assertEquals(listOf("b", "a", "c"), store.roomOrder, "로컬에 바로")
        assertTrue(store.roomOrderPending)
        assertEquals(listOf("b", "a", "c"), changes.last(), "화면도 바로")
        relay.reply(200, snapshot(listOf("b", "a", "c"), 5))
        e.push()
        assertEquals("""{"device":"$DEVICE","rooms":["b","a","c"],"base_revision":4}""", relay.calls.last().body)
        assertEquals("PUT", relay.calls.last().method)
        assertEquals(5L, store.roomOrderRevision)
        assertFalse(store.roomOrderPending)
    }

    @Test fun conflictOnMoveAdoptsServerAndRedraws() {
        val store = MemStore(listOf("a", "b", "c"), revision = 4L)
        val e = engine(store)
        relay.reply(200, snapshot(listOf("a", "b", "c"), 4))
        e.sync()
        e.move(listOf("c", "a", "b"))
        relay.reply(409, conflict(listOf("b", "c", "a"), 6))
        e.push()
        assertEquals(listOf("b", "c", "a"), e.order)
        assertEquals(listOf("b", "c", "a"), store.roomOrder)
        assertEquals(6L, store.roomOrderRevision)
        assertFalse(store.roomOrderPending)
        assertEquals(listOf("b", "c", "a"), changes.last())
    }

    @Test fun moveBeforeFirstFetchAsksFirstThenPushes() {
        // 지난 세션 revision 4 그대로 서버에 있으면 그 위에 올린다(409 로 지우지 않게 GET 부터).
        val store = MemStore(listOf("a", "b"), revision = 4L)
        val e = engine(store)
        e.move(listOf("b", "a"))
        relay.reply(200, snapshot(listOf("a", "b"), 4))
        relay.reply(200, snapshot(listOf("b", "a"), 5))
        e.push()
        assertEquals(listOf("GET", "PUT"), relay.calls.map { it.method })
        assertEquals("""{"device":"$DEVICE","rooms":["b","a"],"base_revision":4}""", relay.calls[1].body)
        assertEquals(listOf("b", "a"), e.order)
        assertEquals(5L, store.roomOrderRevision)
    }

    @Test fun offlineMoveIsRetriedAndNotOverwrittenByTheNextFetch() {
        val store = MemStore(listOf("a", "b"), revision = 2L)
        val e = engine(store)
        relay.reply(200, snapshot(listOf("a", "b"), 2))
        e.sync()
        e.move(listOf("b", "a"))
        relay.noResponse()
        e.push()
        assertTrue(store.roomOrderPending, "올리지 못했다")
        assertFalse(e.isDue())
        clock += RoomOrderSync.MIN_INTERVAL_MS
        assertTrue(e.isDue(), "올리지 못한 변경은 다음 주기에 다시")
        relay.reply(200, snapshot(listOf("a", "b"), 2)) // 그새 아무도 안 바꿨다
        relay.reply(200, snapshot(listOf("b", "a"), 3))
        e.sync()
        assertEquals("""{"device":"$DEVICE","rooms":["b","a"],"base_revision":2}""", relay.calls.last().body)
        assertEquals(listOf("b", "a"), e.order)
        assertEquals(3L, store.roomOrderRevision)
        assertFalse(store.roomOrderPending)
    }

    @Test fun offlineMoveLosesToAChangeMadeElsewhere() {
        val store = MemStore(listOf("b", "a"), revision = 2L, pending = true)
        val e = engine(store)
        relay.reply(200, snapshot(listOf("c", "a", "b"), 3)) // 아이폰이 그새 바꿨다
        e.sync()
        assertEquals(1, relay.calls.size, "PUT 없이 서버 것을 채택")
        assertEquals(listOf("c", "a", "b"), e.order)
        assertFalse(store.roomOrderPending)
    }

    @Test fun moveDuringAnInFlightPutIsSentNext() {
        val store = MemStore(listOf("a", "b", "c"), revision = 1L)
        val e = engine(store)
        relay.reply(200, snapshot(listOf("a", "b", "c"), 1))
        e.sync()
        e.move(listOf("b", "a", "c"))
        var moved = false
        relay.onCall = { call -> if (call.method == "PUT" && !moved) { moved = true; e.move(listOf("c", "b", "a")) } }
        relay.reply(200, snapshot(listOf("b", "a", "c"), 2))
        relay.reply(200, snapshot(listOf("c", "b", "a"), 3))
        e.push()
        assertEquals(3, relay.calls.size)
        assertEquals("""{"device":"$DEVICE","rooms":["c","b","a"],"base_revision":2}""", relay.calls[2].body)
        assertEquals(listOf("c", "b", "a"), e.order)
        assertEquals(3L, store.roomOrderRevision)
        assertFalse(store.roomOrderPending)
    }

    @Test fun badRequestKeepsLocalAndStopsRetrying() {
        val store = MemStore(listOf("a", "b"), revision = 1L)
        val e = engine(store)
        relay.reply(200, snapshot(listOf("a", "b"), 1))
        e.sync()
        e.move(listOf("b", "a"))
        relay.reply(400, """{"error":"duplicate_room"}""")
        e.push()
        assertEquals(listOf("b", "a"), store.roomOrder)
        assertFalse(store.roomOrderPending)
        clock += RoomOrderSync.MIN_INTERVAL_MS
        assertFalse(e.isDue())
    }

    @Test fun moveNormalizesBeforeSaving() {
        val store = MemStore()
        val e = engine(store)
        assertEquals(listOf("a", "b"), e.move(listOf("a", "a", "bad id", "b")))
        assertEquals(listOf("a", "b"), store.roomOrder)
    }

    @Test fun clearForgetsTheSession() {
        val store = MemStore(listOf("a"))
        val e = engine(store)
        relay.reply(404, "")
        e.sync()
        e.clear()
        assertTrue(e.order.isEmpty())
        assertTrue(e.synced)
        assertTrue(e.isDue())
    }

    @Test fun nothingHappensWithoutRelayOrDevice() {
        val e = RoomOrderSync(MemStore(listOf("a")), relayUrl = { null }, device = { DEVICE }, http = relay::send, now = { clock })
        e.sync()
        e.move(listOf("a"))
        e.push()
        assertTrue(relay.calls.isEmpty())
    }

    // ---- 순수 판정 ----

    @Test fun decideTable() {
        fun snap(rev: Long, vararg ids: String) = RoomOrder.Snapshot(ids.toList(), rev, 0L)
        val local = listOf("b", "a")
        assertEquals(RoomOrderSync.Decision.Adopt(snap(3, "a")), RoomOrderSync.decide(snap(3, "a"), local, pending = false, lastRevision = 3))
        assertEquals(RoomOrderSync.Decision.Adopt(snap(3, "a")), RoomOrderSync.decide(snap(3, "a"), local, pending = false, lastRevision = 0))
        assertEquals(RoomOrderSync.Decision.Push(local, 0), RoomOrderSync.decide(snap(0), local, pending = false, lastRevision = 0), "시드")
        assertEquals(RoomOrderSync.Decision.Push(local, 0), RoomOrderSync.decide(snap(0), local, pending = true, lastRevision = 5), "서버가 비었다(복원) — 다시 시드")
        assertEquals(RoomOrderSync.Decision.Keep, RoomOrderSync.decide(snap(0), emptyList(), pending = false, lastRevision = 0))
        assertEquals(RoomOrderSync.Decision.Push(local, 3), RoomOrderSync.decide(snap(3, "a"), local, pending = true, lastRevision = 3), "올리지 못한 변경 재전송")
        assertEquals(RoomOrderSync.Decision.Adopt(snap(4, "a")), RoomOrderSync.decide(snap(4, "a"), local, pending = true, lastRevision = 3), "그새 다른 기기가 바꿨다")
    }

    private companion object {
        const val RELAY = "https://relay.example"
        const val DEVICE = "jinon-android-a1b2c3"
    }
}
