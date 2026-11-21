// `OutgoingBubbles` 고정(#837): 보내는 즉시 「보내는 중」 말풍선 · 누른 순서대로 하나씩 · 받으면 빠짐 · 실패 → 「전송 안 됨」 + 다시 보내기 ·
// 코어 재시도 큐(409 Queued)에 들어간 글은 「보내는 중」으로 남고 poll 의 재시도 이벤트를 큐 순서로 맞춘다. 허브(`DeviceHub`)가 부르는 순서 그대로.
// android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`). 데이터는 합성.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class OutgoingBubblesTest {
    private val room = "family"
    private fun shown(o: OutgoingBubbles, r: String = room) = o.list(r).map { it.text to it.failed }

    /** 허브 `sendOne` 이 보내고 결과를 적는 한 바퀴. */
    private fun sendNext(o: OutgoingBubbles, result: (Long) -> Unit): String {
        val next = assertNotNull(o.takeNext(room))
        result(next.first)
        return next.second
    }

    @Test fun bubblesAppearAtOnceAndAreSentInPressOrder() {
        val o = OutgoingBubbles()
        o.add(room, "첫째")
        o.add(room, "둘째")
        o.add(room, "셋째")
        assertEquals(listOf("첫째" to false, "둘째" to false, "셋째" to false), shown(o), "보내기 전부터 「보내는 중」 말풍선")
        val order = (1..3).map { sendNext(o) { id -> o.sent(id) } }
        assertEquals(listOf("첫째", "둘째", "셋째"), order, "누른 순서대로")
        assertNull(o.takeNext(room))
        assertEquals(emptyList(), shown(o), "받으면 말풍선이 빠진다(이력 행이 대신한다)")
    }

    @Test fun aTakenBubbleIsNotTakenTwice() {
        val o = OutgoingBubbles()
        o.add(room, "하나")
        val first = assertNotNull(o.takeNext(room))
        assertNull(o.takeNext(room), "보내는 중인 글은 다시 꺼내지 않는다")
        assertEquals(listOf("하나" to false), shown(o))
        o.sent(first.first)
        assertEquals(emptyList(), shown(o))
    }

    @Test fun failureShowsFailedAndRetryResendsTheSameTextAtTheEnd() {
        val o = OutgoingBubbles()
        o.add(room, "실패할 글")
        o.add(room, "다음 글")
        val failedId = assertNotNull(o.takeNext(room)).first
        o.failed(failedId)
        sendNext(o) { id -> o.sent(id) }
        assertEquals(listOf("실패할 글" to true), shown(o), "실패한 말풍선 하나만 남는다")
        assertNull(o.retry(room, failedId + 100), "없는 글")
        assertNull(o.retry("other", failedId), "다른 방")
        val again = assertNotNull(o.retry(room, failedId))
        assertTrue(again != failedId, "새 보내는 글")
        assertEquals(listOf("실패할 글" to false), shown(o), "다시 「보내는 중」 — 말풍선은 여전히 하나")
        assertNull(o.retry(room, again), "실패한 글만 다시 보낸다")
        assertEquals("실패할 글", sendNext(o) { id -> o.sent(id) })
        assertEquals(emptyList(), shown(o))
    }

    @Test fun cancelledOrUnexpectedEndNeverLeavesASendingBubble() {
        val o = OutgoingBubbles()
        o.add(room, "끊긴 글")
        val id = assertNotNull(o.takeNext(room)).first
        assertTrue(o.failIfSending(id))
        assertEquals(listOf("끊긴 글" to true), shown(o))
        assertFalse(o.failIfSending(id), "이미 끝난 글은 그대로")
        o.add(room, "보낸 글")
        val sent = assertNotNull(o.takeNext(room)).first
        o.sent(sent)
        assertFalse(o.failIfSending(sent))
    }

    @Test fun queuedStaysSendingUntilTheReplayAndBecomesTheHistoryRow() {
        val o = OutgoingBubbles()
        o.add(room, "밀린 글")
        o.add(room, "그 다음 글")
        sendNext(o) { id -> o.queued(room, id) } // 409 → 코어 재시도 큐
        o.conflict(room, "dad-android-bbbbbb-00000001", attempt = 1) // 처음 보낼 때의 Conflict 는 큐와 무관
        sendNext(o) { id -> o.queued(room, id) }
        assertEquals(listOf("밀린 글" to false, "그 다음 글" to false), shown(o), "대기열 글은 「보내는 중」으로 남는다")
        // 다음 poll: 코어가 큐를 앞에서부터 다시 보낸다(client_id 는 새로 정해진다).
        o.beginPoll(room)
        assertEquals("밀린 글", o.replayed(room, "dad-android-bbbbbb-00000003"))
        assertEquals("그 다음 글", o.replayed(room, "dad-android-bbbbbb-00000004"))
        o.endPoll(room, failed = false)
        assertEquals(emptyList(), shown(o), "이력 행이 되면 말풍선은 빠진다 — 한 개만")
        assertNull(o.replayed(room, "dad-android-bbbbbb-00000005"), "짝 없는 이벤트는 무시")
    }

    @Test fun anotherConflictMovesTheHeadToTheBackLikeTheCore() {
        val o = OutgoingBubbles()
        o.add(room, "A")
        o.add(room, "B")
        repeat(2) { sendNext(o) { id -> o.queued(room, id) } }
        o.beginPoll(room)
        o.conflict(room, "dad-android-bbbbbb-00000003", attempt = 2) // A 또 409 → 뒤로
        assertEquals("B", o.replayed(room, "dad-android-bbbbbb-00000004"))
        o.endPoll(room, failed = false)
        assertEquals(listOf("A" to false), shown(o))
        o.beginPoll(room)
        assertEquals("A", o.replayed(room, "dad-android-bbbbbb-00000005"))
        o.endPoll(room, failed = false)
        assertEquals(emptyList(), shown(o))
    }

    @Test fun attachmentEventsInTheSameQueueAreSkipped() {
        val o = OutgoingBubbles()
        o.add(room, "글")
        sendNext(o) { id -> o.queued(room, id) }
        o.beginPoll(room)
        assertNull(o.replayed(room, "${FileV2.CLIENT_PREFIX}0f8fad5b-d9cb-469f-a165-70867728950e"), "첨부 항목")
        o.conflict(room, "${FileV2.CLIENT_PREFIX}7c9e6679-7425-40de-944b-e07fc1f90ae7", attempt = 3)
        assertEquals("글", o.replayed(room, "dad-android-bbbbbb-00000002"))
        o.endPoll(room, failed = false)
        assertEquals(emptyList(), shown(o))
    }

    @Test fun alreadyDeliveredRemovesTheBubble() {
        val o = OutgoingBubbles()
        o.add(room, "이미 간 글")
        sendNext(o) { id -> o.queued(room, id) }
        o.beginPoll(room)
        o.alreadyDelivered(room, "dad-android-bbbbbb-00000002")
        o.endPoll(room, failed = false)
        assertEquals(emptyList(), shown(o))
    }

    @Test fun droppedMarksTheMatchingTextFailedAndIgnoresAnAttachmentOfAnotherLength() {
        val o = OutgoingBubbles()
        o.add(room, "버려질 글")
        sendNext(o) { id -> o.queued(room, id) }
        o.beginPoll(room)
        o.dropped(room, 4096) // 길이가 다르다 — 첨부 설명자
        assertEquals(listOf("버려질 글" to false), shown(o))
        o.dropped(room, "버려질 글".toByteArray(Charsets.UTF_8).size.toLong())
        o.endPoll(room, failed = false)
        assertEquals(listOf("버려질 글" to true), shown(o), "한도 초과로 버려지면 「전송 안 됨」")
    }

    @Test fun aReplayRoundThatEndsInErrorFailsTheTextsItNeverReached() {
        val o = OutgoingBubbles()
        listOf("하나", "둘", "셋").forEach { o.add(room, it) }
        repeat(3) { sendNext(o) { id -> o.queued(room, id) } }
        o.beginPoll(room)
        assertEquals("하나", o.replayed(room, "dad-android-bbbbbb-00000004"))
        o.dropped(room, "둘".toByteArray(Charsets.UTF_8).size.toLong()) // 전송 오류 → 코어가 남은 항목과 함께 버린다
        o.endPoll(room, failed = true)
        assertEquals(listOf("둘" to true, "셋" to true), shown(o), "코어 큐에서 사라진 글은 「보내는 중」으로 남지 않는다")
    }

    @Test fun aFailedPollThatNeverReachedTheQueueKeepsQueuedTexts() {
        val o = OutgoingBubbles()
        o.add(room, "기다리는 글")
        sendNext(o) { id -> o.queued(room, id) }
        o.beginPoll(room)
        o.endPoll(room, failed = true) // 받아 오기(GET)부터 실패 — 코어 큐는 그대로
        assertEquals(listOf("기다리는 글" to false), shown(o))
        o.beginPoll(room)
        assertEquals("기다리는 글", o.replayed(room, "dad-android-bbbbbb-00000002"))
        o.endPoll(room, failed = false)
        assertEquals(emptyList(), shown(o))
    }

    @Test fun roomsAreIndependentAndWipeClearsEverything() {
        val o = OutgoingBubbles()
        o.add(room, "가족방 글")
        o.add("kids", "아이방 글")
        assertEquals(listOf("가족방 글" to false), shown(o))
        assertEquals(listOf("아이방 글" to false), shown(o, "kids"))
        assertEquals("아이방 글", assertNotNull(o.takeNext("kids")).second)
        o.clear()
        assertEquals(emptyList(), shown(o))
        assertEquals(emptyList(), shown(o, "kids"))
        assertNull(o.takeNext(room))
    }
}
