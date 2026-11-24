// 대화방에서 목록으로 돌아올 때의 스크롤 판단(오너 요청 2026-11-24). android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class RoomListReturnTest {
    private val rooms = (0 until 20).map { "room$it" }

    @Test fun visibleAnchorKeepsThePosition() {
        // 12번 방에서 나왔고 10~16번이 보이면 그대로 — 들어가기 전 위치가 남는다.
        assertNull(RoomListReturn.scrollTarget(rooms, "room12", 10..16))
    }

    @Test fun hiddenAnchorMovesToItsRow() {
        // 그 사이 순서가 바뀌어 화면 밖이면 그 방의 행으로.
        assertEquals(12, RoomListReturn.scrollTarget(rooms, "room12", 0..6))
        assertEquals(0, RoomListReturn.scrollTarget(rooms, "room0", 10..16))
    }

    @Test fun noAnchorOrGoneRoomLeavesTheListAlone() {
        assertNull(RoomListReturn.scrollTarget(rooms, null, 0..6))
        assertNull(RoomListReturn.scrollTarget(rooms, "left-room", 0..6))
        assertNull(RoomListReturn.scrollTarget(emptyList(), "room3", emptyList()))
    }

    @Test fun beforeFirstLayoutNothingIsVisibleSoTheAnchorIsTheTarget() {
        // 첫 배치 전에는 보이는 행이 비어 있다 — 화면은 배치가 끝난 뒤에 묻는다(이 경우를 피하려고).
        assertEquals(5, RoomListReturn.scrollTarget(rooms, "room5", emptyList()))
    }
}
