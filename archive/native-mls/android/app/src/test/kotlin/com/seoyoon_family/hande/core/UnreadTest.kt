// 안 읽음 판정 고정(#571 후속) — 웹 `read-seq.js` 테스트와 같은 경우들. android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class UnreadTest {
    private fun theirs(seq: Long) = MessageUi(seq, "mom-iphone-aaaaaa", "t$seq", mine = false)
    private fun mine(seq: Long) = MessageUi(seq, "dad-android-bbbbbb", "m$seq", mine = true)

    @Test fun emptyRoomIsRead() {
        assertFalse(Unread.isUnread(emptyList(), 0))
        assertEquals(0L, Unread.latestSeq(emptyList()))
    }

    @Test fun lastForeignMessagePastReadSeqIsUnread() {
        val msgs = listOf(theirs(2), theirs(3))
        assertTrue(Unread.isUnread(msgs, 0))
        assertTrue(Unread.isUnread(msgs, 2))
        assertFalse(Unread.isUnread(msgs, 3))
        assertFalse(Unread.isUnread(msgs, 9), "a read position past the last message (another device read further) is read")
        assertEquals(3L, Unread.latestSeq(msgs))
    }

    @Test fun lastOwnMessageIsRead() {
        // 보냈다면 본 것 — 앞의 남의 글이 readSeq 를 넘어도 마지막 글이 내 글이면 배지 없음(iOS·웹과 같은 규칙).
        assertFalse(Unread.isUnread(listOf(theirs(2), mine(3)), 0))
        assertTrue(Unread.isUnread(listOf(mine(2), theirs(3)), 2))
    }

    @Test fun orderIndependent() {
        // 저장소는 seq 순으로 주지만 판정은 가장 큰 seq 를 본다.
        assertTrue(Unread.isUnread(listOf(theirs(5), theirs(4), mine(1)), 4))
        assertEquals(5L, Unread.latestSeq(listOf(theirs(5), theirs(4), mine(1))))
    }
}
