// 대화 목록 순서(#715 room-order v1 · #549) 순수 규칙 — iOS FamilyMLSCore `testRoomOrderOverlayAndMoves`/`testRoomOrderStepAndMoveToTop`·
// 웹 `room-order.test.mjs` 와 같은 경우들 + 릴레이 계약 본문 읽기·쓰기. android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RoomOrderTest {
    private data class Room(val room: String)
    private fun rooms(vararg ids: String) = ids.map { Room(it) }
    private fun List<Room>.ids() = map { it.room }

    @Test fun applyPutsSavedFirstThenDefaultOrder() {
        val rs = rooms("family", "family-acc", "test")
        assertEquals(listOf("family", "family-acc", "test"), RoomOrder.apply(rs, emptyList()) { it.room }.ids())
        assertEquals(listOf("family-acc", "family", "test"), RoomOrder.apply(rs, listOf("family-acc", "gone", "family-acc")) { it.room }.ids(), "없어진 방·중복은 무시")
        assertEquals(listOf("test", "family", "family-acc"), RoomOrder.apply(rs, listOf("test")) { it.room }.ids(), "저장에 없는 방은 기본 순서로 뒤에")
        assertEquals(emptyList(), RoomOrder.apply(emptyList<Room>(), listOf("a")) { it.room })
    }

    @Test fun stepMovesOneSlotAndRefusesEdges() {
        val ids = listOf("a", "b", "c", "d")
        assertEquals(listOf("b", "a", "c", "d"), RoomOrder.step(ids, "b", -1))
        assertEquals(listOf("a", "c", "b", "d"), RoomOrder.step(ids, "b", 1))
        assertNull(RoomOrder.step(ids, "a", -1))
        assertNull(RoomOrder.step(ids, "d", 1))
        assertNull(RoomOrder.step(ids, "zz", 1))
        assertNull(RoomOrder.step(ids, "b", 0))
        assertTrue(RoomOrder.canStep(ids, "a", 1))
        assertFalse(RoomOrder.canStep(ids, "a", -1))
        assertFalse(RoomOrder.canStep(ids, "d", 1))
        assertEquals(listOf("a", "b", "c", "d"), ids, "입력은 바꾸지 않는다")
    }

    @Test fun moveToTop() {
        val ids = listOf("a", "b", "c", "d")
        assertEquals(listOf("c", "a", "b", "d"), RoomOrder.moveToTop(ids, "c"))
        assertEquals(listOf("d", "a", "b", "c"), RoomOrder.moveToTop(ids, "d"))
        assertNull(RoomOrder.moveToTop(ids, "a"))
        assertNull(RoomOrder.moveToTop(ids, "zz"))
        assertNull(RoomOrder.moveToTop(emptyList(), "a"))
    }

    @Test fun steppedVisibleOrderRoundTripsThroughApply() {
        // iOS 와 같은 확인: 화면 순서에서 한 칸 옮긴 결과를 저장하면 apply 가 그대로 돌려준다(저장에 없던 방도 함께 저장되므로 유실 없음).
        val rs = rooms("family", "family-acc", "test")
        val visible = RoomOrder.apply(rs, emptyList()) { it.room }.ids()
        val saved = RoomOrder.withHidden(assertNotNull(RoomOrder.step(visible, "test", -1)), emptyList())
        assertEquals(listOf("family", "test", "family-acc"), RoomOrder.apply(rs, saved) { it.room }.ids())
    }

    @Test fun withHiddenKeepsRoomsThisDeviceDoesNotHave() {
        // 다른 기기(아이폰)에만 있는 방 "ipad-only" 의 자리는 버리지 않고 뒤에 둔다(웹 moveRoom 의 hidden).
        val saved = listOf("b", "ipad-only", "a")
        assertEquals(listOf("a", "b", "ipad-only"), RoomOrder.withHidden(listOf("a", "b"), saved))
        assertEquals(listOf("a", "b"), RoomOrder.withHidden(listOf("a", "b"), listOf("a", "b")))
    }

    @Test fun normalizeDropsDuplicatesBadIdsAndCaps() {
        assertEquals(listOf("a", "b-1", "C_2"), RoomOrder.normalize(listOf("a", "a", "", "b-1", "has space", "dot.ted", "C_2", "한글")))
        assertEquals(listOf("x".repeat(64)), RoomOrder.normalize(listOf("x".repeat(64), "y".repeat(65))), "릴레이 validIdentifier: 1~64자")
        val many = (1..80).map { "r$it" }
        val capped = RoomOrder.normalize(many)
        assertEquals(RoomOrder.LIMIT, capped.size)
        assertEquals("r1", capped.first())
        assertEquals("r64", capped.last(), "앞쪽(화면 위쪽)을 남긴다")
    }

    @Test fun localEncodingRoundTripsAndToleratesGarbage() {
        val ids = listOf("family", "family-acc", "test")
        assertEquals("[\"family\",\"family-acc\",\"test\"]", RoomOrder.encode(ids))
        assertEquals(ids, RoomOrder.decode(RoomOrder.encode(ids)))
        assertEquals("[]", RoomOrder.encode(emptyList()))
        assertEquals(emptyList(), RoomOrder.decode(null))
        assertEquals(emptyList(), RoomOrder.decode(""))
        assertEquals(emptyList(), RoomOrder.decode("not json"))
        assertEquals(emptyList(), RoomOrder.decode("{\"rooms\":[\"a\"]}"), "저장 형식은 배열")
        assertEquals(listOf("a", "b"), RoomOrder.decode("[\"a\",1,null,\"a\",\"b\"]"), "문자열이 아닌 항목·중복은 버린다")
    }

    @Test fun parsesContractBodies() {
        val ok = assertNotNull(RoomOrder.parseSnapshot("""{"rooms":["family","test"],"revision":7,"updated_at":1762400000}"""))
        assertEquals(RoomOrder.Snapshot(listOf("family", "test"), 7L, 1762400000L), ok)
        val empty = assertNotNull(RoomOrder.parseSnapshot("""{"rooms":[],"revision":0,"updated_at":0}"""))
        assertEquals(RoomOrder.Snapshot(emptyList(), 0L, 0L), empty)
        val conflict = assertNotNull(RoomOrder.parseSnapshot("""{"error":"revision_conflict","rooms":["b","a"],"revision":4,"updated_at":5}"""))
        assertEquals(listOf("b", "a"), conflict.rooms)
        assertEquals(4L, conflict.revision)
        assertEquals(0L, assertNotNull(RoomOrder.parseSnapshot("""{"rooms":["a"],"revision":2}""")).updatedAt, "updated_at 이 없으면 0")
        assertEquals(listOf("a"), assertNotNull(RoomOrder.parseSnapshot("""{"rooms":["a","bad id","a"],"revision":2}""")).rooms)
    }

    @Test fun rejectsMalformedBodies() {
        assertNull(RoomOrder.parseSnapshot(""))
        assertNull(RoomOrder.parseSnapshot("[]"))
        assertNull(RoomOrder.parseSnapshot("""{"revision":1}"""), "rooms 없음")
        assertNull(RoomOrder.parseSnapshot("""{"rooms":"a","revision":1}"""))
        assertNull(RoomOrder.parseSnapshot("""{"rooms":[],"revision":-1}"""))
        assertNull(RoomOrder.parseSnapshot("""{"rooms":[],"revision":1.5}"""))
        assertNull(RoomOrder.parseSnapshot("""{"rooms":[],"revision":"3"}"""))
        assertNull(RoomOrder.parseSnapshot("""{"rooms":[],"revision":1,"revision":2}"""), "같은 키 두 번(StrictJson)")
        assertNull(RoomOrder.parseSnapshot("<html>302</html>"))
    }

    @Test fun buildsUrlsAndPutBody() {
        assertEquals("https://relay.example/v2/me/room-order?device=jinon-android-a1b2c3", RoomOrder.getUrl("https://relay.example/", "jinon-android-a1b2c3"))
        assertEquals("https://relay.example/base/v2/me/room-order", RoomOrder.putUrl("https://relay.example/base"))
        assertEquals("http://localhost:8080/v2/me/room-order?device=a%2Bb", RoomOrder.getUrl("http://localhost:8080", "a+b"), "질의 값은 인코딩")
        assertNull(RoomOrder.getUrl("relay.example", "d"))
        assertNull(RoomOrder.putUrl("ftp://relay.example"))
        assertEquals(
            """{"device":"jinon-android-a1b2c3","rooms":["family","test"],"base_revision":3}""",
            RoomOrder.putBody("jinon-android-a1b2c3", listOf("family", "test"), 3L),
        )
        assertEquals("""{"device":"d","rooms":[],"base_revision":0}""", RoomOrder.putBody("d", emptyList(), 0L))
    }
}
