// 하드웨어 키보드 단축키 판정(#833, 순수 로직 — android.* 없이 JVM 단위 테스트). iOS Core `HardwareKeys.swift`(웹 한데 `keyboard.js`·
// `shortcuts.js` #478 의 휴대폰 세로 한 pane 규칙)를 그대로 옮긴다. 화면 연결(Compose 키 → `Press`)은 `ui/HardwareKeyInput.kt`.
//
// 대화방:
//   PageUp/PageDown = 이전·다음 대화방(작성 중이어도 — 초안은 방별 보존) · Home = 대화 목록
//   End 는 어디서나 Esc 와 같다(오너 2026-11-17, #831 — 예전 대화 읽기·선택 모드 End 「맨 아래로」는 없앴다).
//   작성창: Esc·End = 대화 읽기(작성창에서 나온다) · Enter = 전송 · Shift+Enter = 커서 자리에 줄바꿈
//   대화 읽기: ↑/↓ = 위·아래 스크롤(설정 「↑/↓ 키 이동」 #768 — 기본 보이는 칸의 1/3) · Enter = 작성창으로 · Esc·End = 선택 모드
//   선택 모드: 말풍선 하나에 점선 테두리 · ↑/↓ = 테두리 이동(복사할 글이 있는 말풍선만) · Enter = 「선택해서 복사」 창 ·
//     Ctrl+C = 말풍선 글 전체 복사 · Esc·End = 대화 읽기로 · PageUp/PageDown/Home 은 쓰지 않는다(웹 캐럿 모드도 방을 넘기지 않음)
//   Ctrl+V(대화 읽기·선택 모드) = 작성창으로 가서 커서 자리에 붙여넣기
// 대화 목록:
//   PageUp/PageDown = 표시 행을 한 칸씩(열지 않음) · Enter = 표시된 행 열기 · 순서 모드에서는 움직이지 않는다(웹 #480 A)
//
// 수정키 대응: iOS ⌘ → Ctrl(웹과 같음) · ⌥ → Alt · ⌃ → Meta · Shift → Shift.
// 수정키(Ctrl·Alt·Meta·Shift)가 붙은 키는 건드리지 않는다 — Shift+방향키 선택·Ctrl+방향키 단어 이동 같은 편집 동작이다.
// 예외: 작성창 Shift+Enter(줄바꿈) · 선택 모드 Ctrl+C(복사) · 대화 읽기·선택 모드 Ctrl+V(작성창에 붙여넣기).
// iOS 의 두 길(SwiftUI 단축키 + GameController) 중복 거르기(`KeyDeduper`)와 입력칸이 스스로 넣은 줄바꿈 판정(`insertedNewline`)은
// Android 에 없다 — Compose 는 키를 한 길(포커스 노드)로만 준다.
package com.seoyoon_family.hande.core

import kotlin.math.roundToLong

object HardwareKeys {
    enum class Key {
        PAGE_UP, PAGE_DOWN, HOME, END, ESCAPE, UP_ARROW, DOWN_ARROW, ENTER,

        /** 글자 C — 선택 모드 Ctrl+C 복사에만 쓴다. */
        LETTER_C,

        /** 글자 V — 대화 읽기·선택 모드 Ctrl+V(작성창에 붙여넣기)에만 쓴다. */
        LETTER_V,
    }

    /** 눌린 수정키. Caps Lock·Num Lock·Fn 같은 잠금/기능 키는 넣지 않는다. */
    data class Modifiers(val shift: Boolean = false, val ctrl: Boolean = false, val alt: Boolean = false, val meta: Boolean = false) {
        val none: Boolean get() = !shift && !ctrl && !alt && !meta

        companion object {
            val NONE = Modifiers()
            val SHIFT = Modifiers(shift = true)
            val CTRL = Modifiers(ctrl = true)
            val ALT = Modifiers(alt = true)
            val META = Modifiers(meta = true)
        }
    }

    data class Press(val key: Key, val modifiers: Modifiers = Modifiers.NONE)

    // ---- 대화방 ----

    /** 대화방 안에서 키보드가 어디를 다루는가. */
    enum class RoomMode {
        /** 작성창에 커서. */
        COMPOSER,

        /** 작성창 밖 — 대화를 위아래로 읽는다. */
        READING,

        /** 말풍선 하나를 골라 둔 상태(웹 캐럿 모드). */
        SELECTING,
    }

    enum class RoomAction {
        PREVIOUS_ROOM, NEXT_ROOM, BACK_TO_LIST,

        /** 작성창에서 나와 대화 읽기. 선택 모드에서는 선택을 끝내고 읽기로. */
        READ_TIMELINE,

        /** 대화 읽기에서 작성창으로. */
        FOCUS_COMPOSER,
        SCROLL_UP, SCROLL_DOWN,

        /** 작성창 Enter = 보내기 · Shift+Enter = 커서 자리에 줄바꿈. */
        SEND, NEWLINE,

        /** 대화 읽기 Esc·End = 선택 모드 시작. */
        START_SELECTING,

        /** 선택 모드 ↑/↓ = 테두리를 위·아래 말풍선으로. */
        SELECT_UP, SELECT_DOWN,

        /** 선택 모드 Enter = 「선택해서 복사」 창 · Ctrl+C = 글 전체 복사. */
        OPEN_SELECTION, COPY_SELECTION,

        /** 대화 읽기·선택 모드 Ctrl+V = 작성창으로 가서 커서 자리에 붙여넣기. */
        PASTE_TO_COMPOSER,
    }

    /** 대화방 화면에서 이 키가 할 일. 없으면 null(키를 그대로 둔다 — 입력칸·시스템 기본 동작). */
    fun roomAction(press: Press, mode: RoomMode): RoomAction? {
        val key = press.key
        val mods = press.modifiers
        if (mode == RoomMode.COMPOSER && key == Key.ENTER && mods == Modifiers.SHIFT) return RoomAction.NEWLINE
        if (mode == RoomMode.SELECTING && key == Key.LETTER_C && mods == Modifiers.CTRL) return RoomAction.COPY_SELECTION
        if (mode != RoomMode.COMPOSER && key == Key.LETTER_V && mods == Modifiers.CTRL) return RoomAction.PASTE_TO_COMPOSER
        if (!mods.none) return null
        return when (mode) {
            RoomMode.COMPOSER -> when (key) {
                Key.PAGE_UP -> RoomAction.PREVIOUS_ROOM
                Key.PAGE_DOWN -> RoomAction.NEXT_ROOM
                Key.HOME -> RoomAction.BACK_TO_LIST
                Key.ESCAPE, Key.END -> RoomAction.READ_TIMELINE
                Key.ENTER -> RoomAction.SEND
                else -> null
            }
            RoomMode.READING -> when (key) {
                Key.PAGE_UP -> RoomAction.PREVIOUS_ROOM
                Key.PAGE_DOWN -> RoomAction.NEXT_ROOM
                Key.HOME -> RoomAction.BACK_TO_LIST
                Key.UP_ARROW -> RoomAction.SCROLL_UP
                Key.DOWN_ARROW -> RoomAction.SCROLL_DOWN
                Key.ENTER -> RoomAction.FOCUS_COMPOSER
                Key.ESCAPE, Key.END -> RoomAction.START_SELECTING
                else -> null
            }
            RoomMode.SELECTING -> when (key) {
                Key.UP_ARROW -> RoomAction.SELECT_UP
                Key.DOWN_ARROW -> RoomAction.SELECT_DOWN
                Key.ENTER -> RoomAction.OPEN_SELECTION
                Key.ESCAPE, Key.END -> RoomAction.READ_TIMELINE
                else -> null
            }
        }
    }

    /**
     * 키를 누르고 있어 반복 입력(KeyDown repeat)이 와도 다시 할 동작인가 — 스크롤·테두리 이동·방 넘기기·줄바꿈만.
     * 나머지(보내기·작성창 들고나기·선택 모드 들고나기·창 열기·복사·붙여넣기)는 한 번 누름에 한 번이다(반복은 먹기만 한다).
     */
    fun repeats(action: RoomAction): Boolean = when (action) {
        RoomAction.SCROLL_UP, RoomAction.SCROLL_DOWN, RoomAction.SELECT_UP, RoomAction.SELECT_DOWN,
        RoomAction.PREVIOUS_ROOM, RoomAction.NEXT_ROOM, RoomAction.NEWLINE -> true
        else -> false
    }

    /**
     * 선택 모드의 테두리 위치. `rows` = 복사할 글이 있는 말풍선만(첨부 제외), seq 오름차순. 커서가 없으면 마지막 말풍선,
     * 커서가 고를 수 없는 행(첨부 등)이면 그 위의 가장 가까운 말풍선(없으면 첫 말풍선). 이동은 끝에서 멈춘다(맨 아래로 빠지지 않는다).
     * `step` 0 = 시작 위치.
     */
    fun selectTarget(rows: List<Long>, cursor: Long?, step: Int): Long? {
        if (rows.isEmpty()) return null
        val index = if (cursor != null) {
            rows.indexOf(cursor).takeIf { it >= 0 } ?: rows.indexOfLast { it < cursor }.takeIf { it >= 0 } ?: 0
        } else {
            rows.size - 1
        }
        return rows[minOf(rows.size - 1, maxOf(0, index + step))]
    }

    /** 대화 읽기 ↑/↓ 말풍선 단위(설정 「말풍선」)의 목적지. */
    sealed interface ScrollTarget {
        /** 이 말풍선으로. */
        data class Row(val seq: Long) : ScrollTarget

        /** 맨 아래(최신 글). */
        data object Latest : ScrollTarget
    }

    /**
     * 대화 읽기 ↑/↓ — 말풍선 하나씩(설정 「말풍선」, 종전 방식). `cursor` 는 지난번 키로 옮겨 간 행 — 없거나 목록에서 사라졌으면
     * 마지막 말풍선에서 시작한다. 맨 위에서 ↑ 는 제자리, 마지막 말풍선에서 ↓ 는 맨 아래(`Latest`). 글이 없으면 ↓ 만 `Latest`.
     */
    fun scrollTarget(rows: List<Long>, cursor: Long?, up: Boolean): ScrollTarget? {
        if (rows.isEmpty()) return if (up) null else ScrollTarget.Latest
        val index = cursor?.let { c -> rows.indexOf(c).takeIf { it >= 0 } } ?: (rows.size - 1)
        if (up) return ScrollTarget.Row(rows[maxOf(0, index - 1)])
        val next = index + 1
        return if (next < rows.size) ScrollTarget.Row(rows[next]) else ScrollTarget.Latest
    }

    /**
     * 대화 읽기 ↑/↓ 한 번에 움직일 거리 — 설정 「화면」 「↑/↓ 키 이동」(#768). 기본은 보이는 칸 높이의 1/3, 종전 말풍선 단위는 `BUBBLE`.
     * 저장 키·값은 iOS `UserDefaults` 와 같다(`hande.arrowScrollStep` = small/medium/large/bubble).
     */
    enum class ArrowScrollStep(val raw: String) {
        SMALL("small"), MEDIUM("medium"), LARGE("large"), BUBBLE("bubble");

        /** 보이는 칸 높이에 대한 한 번 이동 비율. `BUBBLE` 은 null(말풍선 단위 — `scrollTarget`). 크게(2/3)도 1/3 은 겹쳐 남는다. */
        val viewportFraction: Double?
            get() = when (this) {
                SMALL -> 1.0 / 6.0
                MEDIUM -> 1.0 / 3.0
                LARGE -> 2.0 / 3.0
                BUBBLE -> null
            }

        companion object {
            const val STORAGE_KEY = "hande.arrowScrollStep"
            val STANDARD = MEDIUM

            /** 저장값이 없거나 모르는 값이면 기본(보통). */
            fun from(raw: String?): ArrowScrollStep = entries.firstOrNull { it.raw == raw } ?: STANDARD
        }
    }

    /** 대화 읽기 ↑/↓ 픽셀 이동(작게·보통·크게)의 결과. */
    sealed interface PixelScroll {
        /** 이만큼(px, 위로는 음수) 스크롤. */
        data class By(val pixels: Float) : PixelScroll

        /** 맨 아래(최신 글) — 이미 바닥이다. */
        data object Latest : PixelScroll
    }

    /**
     * 대화 읽기 ↑/↓ — 보이는 칸의 `fraction` 만큼(웹의 픽셀 단위 이동과 같은 뜻, iOS `pixelScrollTarget` 의 LazyColumn 판).
     * Compose `LazyListState` 는 절대 offset 대신 위·아래로 더 갈 수 있는지만 알려 주므로 그것으로 끝을 본다:
     * 맨 위에서 ↑ 는 null(제자리), 맨 아래에서 ↓ 는 `Latest`. 칸 크기를 모르거나 값이 이상하면 null(호출자가 말풍선 단위로 대신한다 —
     * 호출 전에 `viewport > 0` 을 본다).
     */
    fun pixelScroll(viewport: Float, fraction: Double, up: Boolean, canScrollBackward: Boolean, canScrollForward: Boolean): PixelScroll? {
        if (!(viewport > 0f) || !(fraction > 0.0) || viewport.isInfinite() || fraction.isInfinite()) return null
        val step = maxOf(1L, (viewport * fraction).roundToLong()).toFloat()
        if (up) return if (canScrollBackward) PixelScroll.By(-step) else null
        return if (canScrollForward) PixelScroll.By(step) else PixelScroll.Latest
    }

    /** 작성창 글에 끼워 넣은 결과: 새 글 + 커서(끼운 글 바로 뒤). */
    data class Inserted(val text: String, val cursor: Int)

    /**
     * Shift+Enter 줄바꿈·Ctrl+V 붙여넣기: 선택 범위(`start`..`end`, 순서 무관 — 커서만 있으면 같은 값)를 `insert` 로 바꾸고 커서를 그 뒤에 둔다.
     * 범위는 글 길이 안으로 자른다(화면이 오래된 선택을 들고 있어도 깨지지 않게).
     */
    fun insertAt(text: String, start: Int, end: Int, insert: String): Inserted {
        val a = minOf(start, end).coerceIn(0, text.length)
        val b = maxOf(start, end).coerceIn(0, text.length)
        return Inserted(text.substring(0, a) + insert + text.substring(b), a + insert.length)
    }

    /** 이전(-1)/다음(+1) 대화방 — 목록 순서(`ids`)에서. 끝에서는 null(돌아가지 않는다), 목록에 없는 방이면 첫 방(iOS `RoomOrder.neighbor`). */
    fun neighbor(room: String, ids: List<String>, step: Int): String? {
        val index = ids.indexOf(room)
        if (index < 0) return ids.firstOrNull()
        return ids.getOrNull(index + step)
    }

    /**
     * 대화 읽기에서 Enter 로 작성창에 들어간 직후, 그 Enter 를 누르고 있어 반복 입력이 작성창에 오면 저장된 초안을 보내 버린다 —
     * 이 시간 안의 작성창 Enter 전송은 막는다(먹기만 한다). 키 반복은 보통 0.5초 뒤 시작하므로 그보다 조금 길게 둔다(iOS 와 같은 값).
     */
    const val SEND_GUARD_AFTER_KEY_FOCUS_SECONDS = 0.8

    /** `sinceKeyFocus` = Enter 로 작성창에 들어온 뒤 지난 초(없으면 null). true 면 이번 Enter 전송을 막는다. 시계가 뒤로 가면 막지 않는다. */
    fun suppressSend(sinceKeyFocus: Double?): Boolean {
        if (sinceKeyFocus == null) return false
        return sinceKeyFocus >= 0 && sinceKeyFocus < SEND_GUARD_AFTER_KEY_FOCUS_SECONDS
    }

    // ---- 대화 목록 ----

    sealed interface ListAction {
        /** 이 index 의 행을 표시(열지 않는다). */
        data class Highlight(val index: Int) : ListAction

        /** 이 index 의 방을 연다. */
        data class Open(val index: Int) : ListAction
    }

    /**
     * 대화 목록 화면에서 이 키가 할 일. `highlighted` = 키로 표시해 둔 행, `anchor` = 표시가 없을 때 PageUp/Down 의 출발점
     * (방금 나온 방 — 웹 `currentListIndex` 의 열린 방). Enter 는 표시된 행이 있을 때만 연다(보이지 않는 행을 열지 않게).
     */
    fun listAction(press: Press, count: Int, highlighted: Int?, anchor: Int?, orderEditing: Boolean): ListAction? {
        if (!press.modifiers.none || orderEditing || count <= 0) return null
        return when (press.key) {
            Key.PAGE_UP, Key.PAGE_DOWN ->
                pageMove(down = press.key == Key.PAGE_DOWN, count = count, current = highlighted ?: anchor)?.let { ListAction.Highlight(it) }
            Key.ENTER -> if (highlighted != null && highlighted in 0 until count) ListAction.Open(highlighted) else null
            else -> null
        }
    }

    /** 웹 `listPageMove` 와 같다: 출발점이 없거나 범위 밖이면 PageDown 은 첫 행, PageUp 은 마지막 행. 끝에서는 제자리. */
    fun pageMove(down: Boolean, count: Int, current: Int?): Int? {
        if (count <= 0) return null
        if (current == null || current < 0 || current >= count) return if (down) 0 else count - 1
        return minOf(count - 1, maxOf(0, current + if (down) 1 else -1))
    }
}
