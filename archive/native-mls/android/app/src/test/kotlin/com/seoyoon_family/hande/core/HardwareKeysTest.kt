// #833 하드웨어 키보드 단축키 판정 고정 — iOS `HardwareKeysTests.swift`(웹 keyboard.js #478 휴대폰 세로 규칙과의 동등성)를 옮긴 것.
// iOS ⌘ 는 Android Ctrl, ⌥ 는 Alt, ⌃ 는 Meta 로 읽는다. android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`).
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.core.HardwareKeys.ArrowScrollStep
import com.seoyoon_family.hande.core.HardwareKeys.Key
import com.seoyoon_family.hande.core.HardwareKeys.ListAction
import com.seoyoon_family.hande.core.HardwareKeys.Modifiers
import com.seoyoon_family.hande.core.HardwareKeys.PixelScroll
import com.seoyoon_family.hande.core.HardwareKeys.Press
import com.seoyoon_family.hande.core.HardwareKeys.RoomAction
import com.seoyoon_family.hande.core.HardwareKeys.RoomMode
import com.seoyoon_family.hande.core.HardwareKeys.ScrollTarget
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HardwareKeysTest {
    private fun room(key: Key, mode: RoomMode, mods: Modifiers = Modifiers.NONE) = HardwareKeys.roomAction(Press(key, mods), mode)

    @Test fun roomActionsMatchWebSinglePane() {
        // 작성창에 커서가 있을 때.
        assertEquals(RoomAction.PREVIOUS_ROOM, room(Key.PAGE_UP, RoomMode.COMPOSER), "작성 중이어도 방을 넘긴다(웹 'switch')")
        assertEquals(RoomAction.NEXT_ROOM, room(Key.PAGE_DOWN, RoomMode.COMPOSER))
        assertEquals(RoomAction.BACK_TO_LIST, room(Key.HOME, RoomMode.COMPOSER), "웹 viewKeyAction Home")
        assertEquals(RoomAction.READ_TIMELINE, room(Key.ESCAPE, RoomMode.COMPOSER), "웹 'focus-timeline'")
        assertEquals(RoomAction.READ_TIMELINE, room(Key.END, RoomMode.COMPOSER), "End = Esc")
        assertEquals(RoomAction.SEND, room(Key.ENTER, RoomMode.COMPOSER), "웹 composerKeyAction 'send'")
        assertEquals(RoomAction.NEWLINE, room(Key.ENTER, RoomMode.COMPOSER, Modifiers.SHIFT), "'newline'")
        assertNull(room(Key.UP_ARROW, RoomMode.COMPOSER), "작성창 안 커서 이동")
        assertNull(room(Key.DOWN_ARROW, RoomMode.COMPOSER))
        assertNull(room(Key.LETTER_C, RoomMode.COMPOSER), "글자 입력")

        // 대화 읽기(작성창 밖).
        assertEquals(RoomAction.PREVIOUS_ROOM, room(Key.PAGE_UP, RoomMode.READING))
        assertEquals(RoomAction.NEXT_ROOM, room(Key.PAGE_DOWN, RoomMode.READING))
        assertEquals(RoomAction.BACK_TO_LIST, room(Key.HOME, RoomMode.READING))
        assertEquals(RoomAction.SCROLL_UP, room(Key.UP_ARROW, RoomMode.READING), "웹 'scroll-up'")
        assertEquals(RoomAction.SCROLL_DOWN, room(Key.DOWN_ARROW, RoomMode.READING))
        assertEquals(RoomAction.FOCUS_COMPOSER, room(Key.ENTER, RoomMode.READING), "웹 viewKeyAction Enter")
        assertEquals(RoomAction.START_SELECTING, room(Key.END, RoomMode.READING), "End = Esc(2026-11-17, 「맨 아래로」 없앰)")
        assertEquals(RoomAction.START_SELECTING, room(Key.ESCAPE, RoomMode.READING), "웹 'enter-caret'")
        assertNull(room(Key.LETTER_C, RoomMode.READING, Modifiers.CTRL), "고른 말풍선이 없다")

        // 선택 모드(웹 캐럿 모드).
        assertEquals(RoomAction.SELECT_UP, room(Key.UP_ARROW, RoomMode.SELECTING))
        assertEquals(RoomAction.SELECT_DOWN, room(Key.DOWN_ARROW, RoomMode.SELECTING))
        assertEquals(RoomAction.OPEN_SELECTION, room(Key.ENTER, RoomMode.SELECTING))
        assertEquals(RoomAction.COPY_SELECTION, room(Key.LETTER_C, RoomMode.SELECTING, Modifiers.CTRL))
        assertEquals(RoomAction.READ_TIMELINE, room(Key.ESCAPE, RoomMode.SELECTING), "웹 'exit-caret'")
        assertEquals(RoomAction.READ_TIMELINE, room(Key.END, RoomMode.SELECTING), "End = Esc")
        // 웹 캐럿 모드처럼 방을 넘기거나 목록으로 가지 않는다.
        assertNull(room(Key.PAGE_UP, RoomMode.SELECTING))
        assertNull(room(Key.PAGE_DOWN, RoomMode.SELECTING))
        assertNull(room(Key.HOME, RoomMode.SELECTING))
        assertNull(room(Key.LETTER_C, RoomMode.SELECTING))

        // Ctrl+V: 작성창 밖에서는 작성창으로 가서 붙여넣기, 작성창 안은 입력칸 기본 붙여넣기.
        assertEquals(RoomAction.PASTE_TO_COMPOSER, room(Key.LETTER_V, RoomMode.READING, Modifiers.CTRL))
        assertEquals(RoomAction.PASTE_TO_COMPOSER, room(Key.LETTER_V, RoomMode.SELECTING, Modifiers.CTRL))
        assertNull(room(Key.LETTER_V, RoomMode.COMPOSER, Modifiers.CTRL))
        assertNull(room(Key.LETTER_V, RoomMode.READING))
    }

    /** #833 수용 기준: End = Esc 가 세 상황(작성창·대화 읽기·선택 모드) 모두에서 같은 동작 — 수정키가 붙으면 둘 다 가로채지 않는다. */
    @Test fun endIsEscapeEverywhere() {
        for (mode in RoomMode.entries) {
            assertEquals(room(Key.ESCAPE, mode), room(Key.END, mode), "$mode")
            for (mods in listOf(Modifiers.SHIFT, Modifiers.CTRL, Modifiers.ALT, Modifiers.META)) {
                assertNull(room(Key.END, mode, mods), "End $mods $mode")
                assertNull(room(Key.ESCAPE, mode, mods), "Esc $mods $mode")
            }
        }
    }

    @Test fun modifiedKeysAreLeftToEditing() {
        val matrix = listOf(Modifiers.SHIFT, Modifiers.CTRL, Modifiers.ALT, Modifiers.META, Modifiers(shift = true, ctrl = true))
        for (mods in matrix) {
            for (key in Key.entries) {
                for (mode in RoomMode.entries) {
                    val allowed = (mode == RoomMode.COMPOSER && key == Key.ENTER && mods == Modifiers.SHIFT) ||
                        (mode == RoomMode.SELECTING && key == Key.LETTER_C && mods == Modifiers.CTRL) ||
                        (mode != RoomMode.COMPOSER && key == Key.LETTER_V && mods == Modifiers.CTRL)
                    if (allowed) continue
                    assertNull(room(key, mode, mods), "$key $mods $mode")
                }
                assertNull(HardwareKeys.listAction(Press(key, mods), count = 3, highlighted = 1, anchor = null, orderEditing = false), "$key $mods")
            }
        }
        // iOS ⌘↩ 는 입력칸 밖 SwiftUI 단축키가 보낸다 — 판정 표에는 없다(Android 에서도 Ctrl+Enter 는 가로채지 않는다).
        assertNull(room(Key.ENTER, RoomMode.COMPOSER, Modifiers.CTRL))
    }

    @Test fun onlyMovementAndNewlineRepeatWhileHeld() {
        val repeating = setOf(
            RoomAction.SCROLL_UP, RoomAction.SCROLL_DOWN, RoomAction.SELECT_UP, RoomAction.SELECT_DOWN,
            RoomAction.PREVIOUS_ROOM, RoomAction.NEXT_ROOM, RoomAction.NEWLINE,
        )
        for (action in RoomAction.entries) assertEquals(action in repeating, HardwareKeys.repeats(action), "$action")
    }

    @Test fun selectTargetClampsAtEnds() {
        val rows = listOf(10L, 11L, 15L)
        assertEquals(15L, HardwareKeys.selectTarget(rows, cursor = null, step = 0), "시작 = 마지막 말풍선")
        assertEquals(15L, HardwareKeys.selectTarget(rows, cursor = 99L, step = 0), "사라진 커서(맨 아래 뒤) = 위의 가장 가까운 말풍선")
        assertEquals(11L, HardwareKeys.selectTarget(rows, cursor = 12L, step = 0), "첨부 행(12)에서 시작 = 바로 위 말풍선")
        assertEquals(15L, HardwareKeys.selectTarget(rows, cursor = 12L, step = 1))
        assertEquals(10L, HardwareKeys.selectTarget(rows, cursor = 3L, step = 0), "첫 말풍선보다 위 = 첫 말풍선")
        assertEquals(11L, HardwareKeys.selectTarget(rows, cursor = 15L, step = -1))
        assertEquals(10L, HardwareKeys.selectTarget(rows, cursor = 10L, step = -1), "맨 위 제자리")
        assertEquals(15L, HardwareKeys.selectTarget(rows, cursor = 15L, step = 1), "맨 아래로 빠지지 않는다")
        assertEquals(11L, HardwareKeys.selectTarget(rows, cursor = 11L, step = 0), "읽던 자리에서 시작")
        assertNull(HardwareKeys.selectTarget(emptyList(), cursor = null, step = 0))
    }

    @Test fun insertAtReplacesSelectionAndPutsCursorAfter() {
        assertEquals(HardwareKeys.Inserted("\n", 1), HardwareKeys.insertAt("", 0, 0, "\n"))
        assertEquals(HardwareKeys.Inserted("안녕\n", 3), HardwareKeys.insertAt("안녕", 2, 2, "\n"), "끝 커서")
        assertEquals(HardwareKeys.Inserted("a\nb", 2), HardwareKeys.insertAt("ab", 1, 1, "\n"), "가운데 커서")
        assertEquals(HardwareKeys.Inserted("a붙임d", 3), HardwareKeys.insertAt("abcd", 1, 3, "붙임"), "선택 범위를 바꾼다")
        assertEquals(HardwareKeys.Inserted("a붙임d", 3), HardwareKeys.insertAt("abcd", 3, 1, "붙임"), "거꾸로 잡은 범위도 같다")
        assertEquals(HardwareKeys.Inserted("ab!", 3), HardwareKeys.insertAt("ab", 7, 9, "!"), "글보다 긴 범위는 끝으로 자른다")
        assertEquals(HardwareKeys.Inserted("!ab", 1), HardwareKeys.insertAt("ab", -3, -1, "!"))
    }

    @Test fun neighborStopsAtEnds() {
        // iOS AgentConversationTests `RoomOrder.neighbor` 와 같다.
        val ids = listOf("a", "b", "c", "d")
        assertEquals("c", HardwareKeys.neighbor("b", ids, 1))
        assertEquals("a", HardwareKeys.neighbor("b", ids, -1))
        assertNull(HardwareKeys.neighbor("a", ids, -1), "끝에서는 돌아가지 않는다")
        assertNull(HardwareKeys.neighbor("d", ids, 1))
        assertEquals("a", HardwareKeys.neighbor("zz", ids, 1), "목록에 없는 방 = 첫 방")
        assertNull(HardwareKeys.neighbor("zz", emptyList(), 1))
    }

    @Test fun pageMoveMatchesWebListPageMove() {
        // 웹 keyboard.test: 출발점 없음 → PageDown 첫 행 · PageUp 마지막 행, 끝에서는 제자리, 빈 목록은 null.
        assertEquals(0, HardwareKeys.pageMove(down = true, count = 3, current = null))
        assertEquals(2, HardwareKeys.pageMove(down = false, count = 3, current = null))
        assertEquals(1, HardwareKeys.pageMove(down = true, count = 3, current = 0))
        assertEquals(0, HardwareKeys.pageMove(down = false, count = 3, current = 1))
        assertEquals(2, HardwareKeys.pageMove(down = true, count = 3, current = 2))
        assertEquals(0, HardwareKeys.pageMove(down = false, count = 3, current = 0))
        assertEquals(0, HardwareKeys.pageMove(down = true, count = 3, current = 7), "범위 밖 = 출발점 없음")
        assertEquals(2, HardwareKeys.pageMove(down = false, count = 3, current = -1))
        assertNull(HardwareKeys.pageMove(down = true, count = 0, current = null))
    }

    @Test fun listActions() {
        fun list(key: Key, count: Int, highlighted: Int?, anchor: Int?, orderEditing: Boolean = false) =
            HardwareKeys.listAction(Press(key), count, highlighted, anchor, orderEditing)
        // 표시가 없으면 방금 나온 방(anchor)에서 출발한다.
        assertEquals(ListAction.Highlight(2), list(Key.PAGE_DOWN, 4, highlighted = null, anchor = 1))
        assertEquals(ListAction.Highlight(0), list(Key.PAGE_UP, 4, highlighted = null, anchor = 1))
        assertEquals(ListAction.Highlight(0), list(Key.PAGE_DOWN, 4, highlighted = null, anchor = null))
        // 표시가 있으면 표시에서 출발한다(anchor 보다 먼저).
        assertEquals(ListAction.Highlight(3), list(Key.PAGE_DOWN, 4, highlighted = 3, anchor = 0))
        // Enter 는 표시된 행만 연다 — 보이지 않는 출발점(anchor)은 열지 않는다.
        assertEquals(ListAction.Open(2), list(Key.ENTER, 4, highlighted = 2, anchor = null))
        assertNull(list(Key.ENTER, 4, highlighted = null, anchor = 2))
        assertNull(list(Key.ENTER, 2, highlighted = 5, anchor = null))
        // 순서 모드·빈 목록에서는 아무것도 하지 않는다(웹 #480 A).
        assertNull(list(Key.PAGE_DOWN, 4, highlighted = null, anchor = null, orderEditing = true))
        assertNull(list(Key.ENTER, 4, highlighted = 1, anchor = null, orderEditing = true))
        assertNull(list(Key.PAGE_DOWN, 0, highlighted = null, anchor = null))
        // 목록 화면의 다른 키는 쓰지 않는다(Esc 는 시스템 「뒤로」 그대로).
        for (key in listOf(Key.HOME, Key.END, Key.ESCAPE, Key.UP_ARROW, Key.DOWN_ARROW)) {
            assertNull(list(key, 4, highlighted = 1, anchor = null), "$key")
        }
    }

    @Test fun scrollTargetStepsOneBubble() {
        val rows = listOf(10L, 11L, 15L, 20L)
        // 커서 없음(방금 읽기 시작) = 마지막 말풍선 기준.
        assertEquals(ScrollTarget.Row(15L), HardwareKeys.scrollTarget(rows, cursor = null, up = true))
        assertEquals(ScrollTarget.Latest, HardwareKeys.scrollTarget(rows, cursor = null, up = false))
        assertEquals(ScrollTarget.Row(11L), HardwareKeys.scrollTarget(rows, cursor = 15L, up = true))
        assertEquals(ScrollTarget.Row(15L), HardwareKeys.scrollTarget(rows, cursor = 11L, up = false))
        assertEquals(ScrollTarget.Row(20L), HardwareKeys.scrollTarget(rows, cursor = 15L, up = false))
        assertEquals(ScrollTarget.Latest, HardwareKeys.scrollTarget(rows, cursor = 20L, up = false))
        assertEquals(ScrollTarget.Row(10L), HardwareKeys.scrollTarget(rows, cursor = 10L, up = true), "맨 위 제자리")
        assertEquals(ScrollTarget.Row(15L), HardwareKeys.scrollTarget(rows, cursor = 99L, up = true), "사라진 커서 = 마지막에서 다시")
        assertNull(HardwareKeys.scrollTarget(emptyList(), cursor = null, up = true))
        assertEquals(ScrollTarget.Latest, HardwareKeys.scrollTarget(emptyList(), cursor = null, up = false))
    }

    @Test fun arrowScrollStepDefaultsToThirdOfViewport() {
        assertEquals(ArrowScrollStep.MEDIUM, ArrowScrollStep.from(null), "저장값 없음 = 보통(1/3)")
        assertEquals(ArrowScrollStep.MEDIUM, ArrowScrollStep.from("bogus"), "모르는 값 = 보통")
        assertEquals(ArrowScrollStep.BUBBLE, ArrowScrollStep.from("bubble"), "종전 말풍선 단위")
        assertEquals(ArrowScrollStep.LARGE, ArrowScrollStep.from("large"))
        assertEquals(ArrowScrollStep.SMALL, ArrowScrollStep.from("small"))
        assertEquals(ArrowScrollStep.MEDIUM, ArrowScrollStep.STANDARD)
        assertEquals("hande.arrowScrollStep", ArrowScrollStep.STORAGE_KEY, "iOS UserDefaults 키와 같다")
        assertEquals(listOf("small", "medium", "large", "bubble"), ArrowScrollStep.entries.map { it.raw }, "iOS rawValue 와 같은 값·순서")
        assertEquals(1.0 / 3.0, ArrowScrollStep.MEDIUM.viewportFraction)
        assertNull(ArrowScrollStep.BUBBLE.viewportFraction)
        // 작게 < 보통 < 크게 < 한 화면(겹침이 남는다).
        val fractions = listOf(ArrowScrollStep.SMALL, ArrowScrollStep.MEDIUM, ArrowScrollStep.LARGE).mapNotNull { it.viewportFraction }
        assertEquals(fractions.sorted(), fractions)
        assertTrue(fractions.last() < 1.0)
    }

    @Test fun pixelScrollMovesFractionOfViewport() {
        // 보이는 칸 600, 1/3 = 200 (iOS `testPixelScrollTargetMovesFractionOfViewport` 와 같은 칸·비율).
        fun t(up: Boolean, back: Boolean = true, forward: Boolean = true, fraction: Double = 1.0 / 3.0) =
            HardwareKeys.pixelScroll(600f, fraction, up, canScrollBackward = back, canScrollForward = forward)
        assertEquals(PixelScroll.By(-200f), t(up = true))
        assertEquals(PixelScroll.By(200f), t(up = false))
        assertNull(t(up = true, back = false), "맨 위 ↑ = 제자리")
        assertEquals(PixelScroll.Latest, t(up = false, forward = false), "맨 아래 ↓ = 최신 글")
        assertEquals(PixelScroll.By(-100f), t(up = true, fraction = 1.0 / 6.0))
        assertEquals(PixelScroll.By(-400f), t(up = true, fraction = 2.0 / 3.0))
        assertEquals(PixelScroll.By(1f), HardwareKeys.pixelScroll(1f, 0.1, up = false, canScrollBackward = true, canScrollForward = true), "최소 1px")
        // 칸 크기를 아직 모름·이상한 값 — 호출자가 말풍선 단위로 대신한다.
        assertNull(HardwareKeys.pixelScroll(0f, 1.0 / 3.0, up = false, canScrollBackward = true, canScrollForward = true))
        assertNull(HardwareKeys.pixelScroll(Float.NaN, 1.0 / 3.0, up = false, canScrollBackward = true, canScrollForward = true))
        assertNull(HardwareKeys.pixelScroll(600f, Double.NaN, up = false, canScrollBackward = true, canScrollForward = true))
    }

    @Test fun sendGuardAfterEnterFocus() {
        assertFalse(HardwareKeys.suppressSend(null), "손으로 작성창을 누른 경우")
        assertTrue(HardwareKeys.suppressSend(0.0))
        assertTrue(HardwareKeys.suppressSend(0.55), "키 반복으로 들어온 Enter")
        assertFalse(HardwareKeys.suppressSend(0.8))
        assertFalse(HardwareKeys.suppressSend(5.0))
        assertFalse(HardwareKeys.suppressSend(-1.0), "시계 역행은 막지 않는다")
    }
}
