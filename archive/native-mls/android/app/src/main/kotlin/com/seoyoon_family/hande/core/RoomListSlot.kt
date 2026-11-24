// 방 목록 줄의 미리보기 자리(#870, AGENT-CHOICES-V1 §7) — 웹 `roomPreviewSlot`·iOS `CampfireCard` 와 같은 우선순위.
// 꺼진 자리·참여 전 > 답변 필요 > status-v1 Working/대기 중 줄(#560) > 평소 미리보기. android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

object RoomListSlot {
    enum class Kind { HALTED, NOT_JOINED, ANSWER, WORKING, PREVIEW }

    fun kind(halted: Boolean, joined: Boolean, working: String?, answer: AgentChoices.RoomAnswer?): Kind = when {
        halted -> Kind.HALTED
        !joined -> Kind.NOT_JOINED
        answer != null -> Kind.ANSWER
        working != null -> Kind.WORKING
        else -> Kind.PREVIEW
    }
}
