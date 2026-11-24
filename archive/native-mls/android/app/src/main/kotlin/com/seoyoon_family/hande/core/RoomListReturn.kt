// 대화방에서 목록으로 돌아왔을 때의 스크롤 판단(오너 요청 2026-11-24). android.* 없이 JVM 에서 돈다.
// 목록 위치 자체는 화면(HandeRoot)이 저장해 두고, 여기서는 「방금 나온 방이 화면 밖이면 어디로 옮길지」만 정한다.
package com.seoyoon_family.hande.core

object RoomListReturn {
    /**
     * 돌아왔을 때 옮길 행 번호, 옮기지 않을 때는 null.
     * - 방금 나온 방이 없거나 목록에 없으면(나갔거나 사라진 방) 그대로 둔다.
     * - 그 방이 이미 화면에 보이면 그대로 둔다 — 사용자가 보던 위치를 지킨다.
     * - 보이지 않으면(그 사이 순서가 바뀜 등) 그 방의 행으로 옮긴다.
     */
    fun scrollTarget(rooms: List<String>, anchorRoom: String?, visibleRows: Collection<Int>): Int? {
        val anchor = anchorRoom?.let { rooms.indexOf(it) }?.takeIf { it >= 0 } ?: return null
        return if (anchor in visibleRows) null else anchor
    }
}
