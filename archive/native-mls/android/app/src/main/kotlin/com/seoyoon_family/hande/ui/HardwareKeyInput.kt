// 하드웨어 키보드 단축키(#833)의 Compose 연결 조각 — 판정은 `core/HardwareKeys`·`core/AgentChoiceKeys`(순수, JVM 테스트), 여기는 키 읽기와 그리기만.
// 대화방 키는 화면 뿌리의 `onPreInterceptKeyBeforeSoftKeyboard`(IME 보다 먼저 — 하드웨어 키만 온다. 한글 조합 중 Esc·End·Home·PageUp/Down·Enter 가
// IME 에 먹히지 않게, 작성창 모드는 여기서만 판정)와 `onPreviewKeyEvent`(IME 뒤 — 작성창 밖 모드만, 앞에서 처리한 키는 오지 않는다)에서 받는다.
package com.seoyoon_family.hande.ui

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.dp
import com.seoyoon_family.hande.core.AgentChoiceKeys
import com.seoyoon_family.hande.core.HardwareKeys

/**
 * 화면 키보드(IME)가 InputConnection 으로 보낸 키인가(`FLAG_SOFT_KEYBOARD`). 화면 키보드 Enter 는 늘 줄바꿈이고(iOS 와 같다)
 * 단축키 표는 하드웨어 키보드 것이라 이런 키는 판정하지 않는다.
 */
internal fun KeyEvent.fromSoftKeyboard(): Boolean = (nativeKeyEvent.flags and AndroidKeyEvent.FLAG_SOFT_KEYBOARD) != 0

/** 누르고 있어 반복 입력된 KeyDown 인가. */
internal fun KeyEvent.isRepeat(): Boolean = nativeKeyEvent.repeatCount > 0

/** 수정키(iOS ⌘ → Ctrl · ⌥ → Alt · ⌃ → Meta). Caps Lock·Num Lock·Fn 은 넣지 않는다. */
internal fun KeyEvent.hardwareModifiers(): HardwareKeys.Modifiers =
    HardwareKeys.Modifiers(shift = isShiftPressed, ctrl = isCtrlPressed, alt = isAltPressed, meta = isMetaPressed)

/** 표에 있는 키면 `Press`, 아니면 null(그대로 둔다). Home·End 는 키보드의 `MOVE_HOME`·`MOVE_END`(시스템 홈 키가 아니다). */
internal fun KeyEvent.hardwarePress(): HardwareKeys.Press? {
    val mapped = when (key) {
        Key.PageUp -> HardwareKeys.Key.PAGE_UP
        Key.PageDown -> HardwareKeys.Key.PAGE_DOWN
        Key.MoveHome -> HardwareKeys.Key.HOME
        Key.MoveEnd -> HardwareKeys.Key.END
        Key.Escape -> HardwareKeys.Key.ESCAPE
        Key.DirectionUp -> HardwareKeys.Key.UP_ARROW
        Key.DirectionDown -> HardwareKeys.Key.DOWN_ARROW
        Key.Enter, Key.NumPadEnter -> HardwareKeys.Key.ENTER
        Key.C -> HardwareKeys.Key.LETTER_C
        Key.V -> HardwareKeys.Key.LETTER_V
        else -> return null
    }
    return HardwareKeys.Press(mapped, hardwareModifiers())
}

private val DIGIT_KEYS = listOf(Key.Zero, Key.One, Key.Two, Key.Three, Key.Four, Key.Five, Key.Six, Key.Seven, Key.Eight, Key.Nine)
private val NUMPAD_KEYS = listOf(
    Key.NumPad0, Key.NumPad1, Key.NumPad2, Key.NumPad3, Key.NumPad4, Key.NumPad5, Key.NumPad6, Key.NumPad7, Key.NumPad8, Key.NumPad9,
)

/** 선택지 카드 단축키 입력(agent-choices-v1 §3.1). 숫자는 윗줄·숫자 패드 모두 물리 키 번호로 본다. */
internal fun KeyEvent.choiceInput(composing: Boolean): AgentChoiceKeys.Input {
    val digit = DIGIT_KEYS.indexOf(key).takeIf { it >= 0 } ?: NUMPAD_KEYS.indexOf(key).takeIf { it >= 0 }
    val mapped = when {
        digit != null -> AgentChoiceKeys.Key.Digit(digit)
        key == Key.Enter || key == Key.NumPadEnter -> AgentChoiceKeys.Key.Enter
        else -> AgentChoiceKeys.Key.Other
    }
    return AgentChoiceKeys.Input(mapped, alt = isAltPressed, ctrl = isCtrlPressed, meta = isMetaPressed, shift = isShiftPressed, composing = composing)
}

/**
 * 처리한 키의 KeyUp 도 먹는다: KeyDown 만 먹고 KeyUp 을 흘리면 입력칸이 짝 없는 Up 을 받고, Esc 는 처리하지 않은 키로 보여
 * 시스템이 「뒤로」 대체 키를 만들 수 있다. 처리한 Esc 는 앱을 뒤로 보내지 않는다(#833 수용 기준). 처리하지 않은 키(목록의 Esc 등)는 그대로.
 */
internal class HeldKeys {
    private val held = HashSet<Long>()

    /** KeyDown: [onDown] 이 처리했으면(true) 기억한다. KeyUp: 기억한 키면 지우고 먹는다. */
    fun dispatch(event: KeyEvent, onDown: () -> Boolean): Boolean = when (event.type) {
        KeyEventType.KeyDown -> onDown().also { handled -> if (handled) held.add(event.key.keyCode) else held.remove(event.key.keyCode) }
        KeyEventType.KeyUp -> held.remove(event.key.keyCode)
        else -> false
    }
}

/**
 * 키로 고른 말풍선의 점선 테두리(선택 모드). 자리를 차지하지 않게 행 바깥 3dp 에 그린다 — 테두리를 켜고 꺼도 말풍선이 움직이지 않는다.
 */
internal fun Modifier.keySelectionOutline(selected: Boolean, color: Color): Modifier =
    if (!selected) this else drawBehind {
        val out = 3.dp.toPx()
        val width = 1.5.dp.toPx()
        drawRoundRect(
            color,
            topLeft = Offset(-out, -out),
            size = Size(size.width + out * 2, size.height + out * 2),
            cornerRadius = CornerRadius(12.dp.toPx()),
            style = Stroke(width = width, pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx()))),
        )
    }

/** `index` 항목이 다 보이게 최소한으로 스크롤한다(이미 다 보이면 그대로, 칸보다 크면 위를 맞춘다). */
internal suspend fun LazyListState.reveal(index: Int) {
    val info = layoutInfo
    val item = info.visibleItemsInfo.firstOrNull { it.index == index }
    if (item == null) {
        animateScrollToItem(index)
        return
    }
    val top = 0
    val bottom = info.viewportEndOffset - info.afterContentPadding
    val end = item.offset + item.size
    when {
        item.offset < top -> animateScrollBy((item.offset - top).toFloat())
        end > bottom -> animateScrollBy(minOf(end - bottom, item.offset - top).toFloat())
    }
}
