// agent-choices-v1 §3.1(#629 · Android #833) — 선택지 카드 키보드 단축키 판정(순수 로직, android.* 없이 JVM 단위 테스트).
// 정본: archive/native-mls/AGENT-CHOICES-V1.md §3.1 · 공유 벡터 tests/fixtures/agent-choices-vectors.json `keys`(웹 `choiceKeyAction`·iOS `AgentChoiceKeys` 와 같은 답).
//
// Alt+1~9 = 방의 open 카드에서 그 번호 체크 토글 · Alt+Enter = 체크가 하나 이상이면 보내기(카드 [보내기]와 같은 compose 전송).
// Alt 만 눌려 있어야 한다(Ctrl·Meta·Shift 하나라도 있으면 null) · IME 조합 중이면 null · 카드가 없거나 비활성이면 null · N 이 1..k 밖이면 null.
// null = 가로채지 않는다(Alt+숫자 특수문자 입력·기존 Enter 규칙 그대로). 벡터의 alt/ctrl/meta/shift 는 Android 의 같은 이름 수정키다.
// `HardwareKeys`(방 이동·읽기 모드)와는 따로 둔다 — 수정키가 붙은 키는 그쪽이 건드리지 않는다.
package com.seoyoon_family.hande.core

object AgentChoiceKeys {
    /** 눌린 키. 숫자는 물리 숫자 키(윗줄 1~9 · 숫자 패드 1~9)로 본다. */
    sealed interface Key {
        data class Digit(val number: Int) : Key
        data object Enter : Key
        data object Other : Key
    }

    data class Input(
        val key: Key,
        val alt: Boolean = false,
        val ctrl: Boolean = false,
        val meta: Boolean = false,
        val shift: Boolean = false,
        /** IME 조합 중(한글 등 확정 전 글자가 있다). */
        val composing: Boolean = false,
    )

    /** 방의 open 선택지 카드(방당 최대 1개). */
    data class Card(
        /** 항목 수 k. */
        val count: Int,
        /** 지금 체크된 번호. */
        val selected: Set<Int>,
        /** 카드가 활성(보내는 중·참여 전·꺼진 자리가 아님). */
        val enabled: Boolean,
    )

    sealed interface Action {
        /** 그 번호 체크 토글. */
        data class Toggle(val number: Int) : Action

        /** 체크한 번호로 보내기. */
        data object Send : Action
    }

    /** 단축키 판정(규격 §3.1). null = 가로채지 않음. */
    fun decide(input: Input, card: Card?): Action? {
        if (card == null || !card.enabled) return null
        if (!input.alt || input.ctrl || input.meta || input.shift || input.composing) return null
        return when (val key = input.key) {
            is Key.Digit -> if (key.number in 1..9 && key.number <= card.count) Action.Toggle(key.number) else null
            Key.Enter -> if (card.selected.isEmpty()) null else Action.Send
            Key.Other -> null
        }
    }
}
