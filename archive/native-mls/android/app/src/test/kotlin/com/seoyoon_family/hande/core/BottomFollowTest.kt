// 대화방 바닥 따라가기(BottomFollow) — 들어오면 최신 글, 뒤늦게 커지는 행에도 바닥 유지, 손으로 올리면 끄기.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BottomFollowTest {
    @Test fun startsFollowingSoEnteringARoomShowsLatest() {
        val f = BottomFollow()
        assertTrue(f.isFollowing)
        // 방을 연 첫 배치: 맨 위에 있고 아래로 더 갈 수 있다 → 바닥으로.
        assertTrue(f.observe(scrollInProgress = false, canScrollForward = true))
    }

    @Test fun lateGrowingRowAtBottomPullsBackDown() {
        val f = BottomFollow()
        assertFalse(f.observe(scrollInProgress = false, canScrollForward = false), "이미 바닥 — 움직이지 않는다")
        // 썸네일·링크 카드가 늦게 그려져 최신 글이 밀려났다(스크롤 없이 아래로 갈 수 있게 됨).
        assertTrue(f.observe(scrollInProgress = false, canScrollForward = true))
    }

    @Test fun userScrollUpStopsFollowing() {
        val f = BottomFollow()
        f.observe(scrollInProgress = false, canScrollForward = false)
        assertFalse(f.observe(scrollInProgress = true, canScrollForward = true), "끄는 동안은 손대지 않는다")
        assertFalse(f.observe(scrollInProgress = false, canScrollForward = true), "바닥이 아닌 곳에서 멈춤 = 읽는 중")
        assertFalse(f.isFollowing)
        // 읽는 동안 위쪽 행이 커져도 끌어내리지 않는다.
        assertFalse(f.observe(scrollInProgress = false, canScrollForward = true))
    }

    @Test fun scrollEndingAtBottomResumesFollowing() {
        val f = BottomFollow()
        f.observe(scrollInProgress = true, canScrollForward = true)
        f.observe(scrollInProgress = false, canScrollForward = true)
        assertFalse(f.isFollowing)
        f.observe(scrollInProgress = true, canScrollForward = true)
        assertFalse(f.observe(scrollInProgress = false, canScrollForward = false), "바닥에서 멈춤")
        assertTrue(f.isFollowing)
        assertTrue(f.observe(scrollInProgress = false, canScrollForward = true), "그 뒤 커지는 행에는 다시 따라간다")
    }

    @Test fun reachingBottomWithoutSeenScrollResumesFollowing() {
        // 화면이 마지막 항목으로 간 뒤 남은 만큼 더 내리는 사이(바닥 전)를 보고, 두 번째 스크롤 중 상태는 못 본 경우.
        val f = BottomFollow()
        f.observe(scrollInProgress = true, canScrollForward = true)
        f.observe(scrollInProgress = false, canScrollForward = true)
        assertFalse(f.isFollowing)
        assertFalse(f.observe(scrollInProgress = false, canScrollForward = false), "바닥 도착")
        assertTrue(f.isFollowing)
        assertTrue(f.observe(scrollInProgress = false, canScrollForward = true))
    }
}
