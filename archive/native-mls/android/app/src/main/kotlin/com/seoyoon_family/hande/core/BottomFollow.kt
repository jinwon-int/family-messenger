// 대화방 바닥 따라가기 — iOS RoomView `followLatest` 의 Android 판. android.* 없이 JVM 에서 돈다(BottomFollowTest).
package com.seoyoon_family.hande.core

/**
 * 바닥(최신 글)에 머물던 동안 뒤늦게 커지는 행(사진 썸네일 · 링크 미리보기 카드 · 선택지 카드)이나 작성창 키보드로 칸이 줄어
 * 최신 글이 칸 아래로 밀려나면 다시 바닥으로 내린다. 손가락·↑ 키로 올려서 멈추면 따라가기를 끄고, 스크롤이 바닥에서 멈추면 다시 켠다.
 *
 * 화면은 `LazyListState` 의 (스크롤 중인가, 아래로 더 갈 수 있나)가 바뀔 때마다 [observe] 를 부르고, true 면 바닥으로 내린다.
 * 스크롤 중이 아닌데 아래로 더 갈 수 있게 됐다 = 스크롤이 아니라 내용·칸 크기가 바뀌었다는 뜻이다.
 */
class BottomFollow {
    private var following = true
    private var scrolling = false

    /** 지금 따라가는 중인가(바닥에 있거나, 마지막 스크롤이 바닥에서 멈췄다). */
    val isFollowing: Boolean get() = following

    /** true = 지금 바닥으로 다시 내려야 한다. */
    fun observe(scrollInProgress: Boolean, canScrollForward: Boolean): Boolean {
        if (scrollInProgress) {
            scrolling = true
            return false
        }
        if (scrolling) {
            // 스크롤(손가락·키·코드)이 방금 끝났다 — 끝난 자리가 바닥이면 따라가고, 아니면 사람이 읽는 중이다.
            scrolling = false
            following = !canScrollForward
            return false
        }
        if (!canScrollForward) {
            // 바닥이다(어떻게 왔든 — 화면이 두 번에 나눠 내린 사이를 보았어도 여기서 바로잡힌다).
            following = true
            return false
        }
        return following
    }
}
