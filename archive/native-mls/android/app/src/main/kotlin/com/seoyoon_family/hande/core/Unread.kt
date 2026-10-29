// 안 읽음 판정(#571 후속) — 웹 `web/hande/read-seq.js isUnread/latestSeq` · iOS `Unread.isUnread` 와 같은 규칙.
// 안 읽음 = 마지막 글이 남의 글이고(`MessageUi.mine` 은 actor 기준 — 같은 사람의 다른 기기 글은 내 글) 본 위치(readSeq)보다 뒤.
// readSeq = max(이 기기 로컬 값 `Settings.readSeq`, 릴레이의 actor 단위 값 `MlsRoom.readSeq()`) — 어느 기기에서 읽든 함께 꺼진다.
// android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`).
package com.seoyoon_family.hande.core

object Unread {
    /** 방의 마지막(가장 큰) seq. 글이 없으면 0. */
    fun latestSeq(messages: List<MessageUi>): Long = messages.maxOfOrNull { it.seq } ?: 0L

    /** 마지막 글이 내 글이면 안 읽음 아님(보냈다면 본 것). */
    fun isUnread(messages: List<MessageUi>, readSeq: Long): Boolean {
        val last = messages.maxByOrNull { it.seq } ?: return false
        return !last.mine && last.seq > readSeq
    }
}
