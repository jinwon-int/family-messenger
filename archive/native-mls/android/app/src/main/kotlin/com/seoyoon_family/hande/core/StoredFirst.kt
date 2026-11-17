// 저장된 방·대화로 먼저 그리기(#766 B). 방·대화는 기기에 저장돼 있다(`<room>.state` · `messages.db`) — `boot` 가 그것을 읽으면
// 릴레이 응답을 기다리지 않고 목록·대화를 보이고(`Phase.Stored`), `probe` 와 sync 는 그 뒤에 이어진다.
// 전에는 `boot` 끝의 `probe` 가 성공해야 `Starting` 을 벗어났다(왕복 약 0.3초, 일시 실패면 다음 시도는 3틱 뒤).
// 세션이 확인되기 전(`Stored`)에는 저장된 것을 **보이기만** 한다 — 보내기·첨부·참여 요청·읽음 올리기·방 poll·로비 쪽 일은 전과 같이 `Ready` 에서만.
// 여기는 그 단계 전이의 순수 판정이다. android.* 없음 — JVM 단위 테스트(`StoredFirstTest`)로 돈다.
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.ui.Strings

object StoredFirst {
    /**
     * `boot` 가 저장된 것을 화면 상태에 실은 직후, `probe` **전**: 저장된 신원(로비 슬롯)과 방이 있으면 `Starting` → `Stored`(+ 「연결 중」 표시).
     * 처음 실행(신원 없음) · 방 없음 · `Starting` 이 아닌 단계는 그대로 — 전처럼 `probe` 결과를 기다린다.
     */
    fun loaded(ui: HubUi, identityStored: Boolean): HubUi =
        if (ui.phase is Phase.Starting && identityStored && ui.rooms.isNotEmpty()) ui.copy(phase = Phase.Stored, connecting = true) else ui

    /** `probe` 성공: 어느 단계에서 왔든 `Ready`. 등록 대기에서 왔으면([wasWaiting]) 「등록되었습니다」 알림. */
    fun probeOk(ui: HubUi, live: Int, max: Int, wasWaiting: Boolean): HubUi =
        ui.copy(phase = Phase.Ready, lobbyLive = live, lobbyMax = max, connecting = false, notice = if (wasWaiting) Strings.enrolledNow else null)

    /**
     * `probe` 실패: [classified](등록 대기 · 로그인 필요)가 있으면 그 단계로, 없으면(일시 오류 등) 지금 단계 그대로 — `Stored` 면 저장된
     * 목록·대화가 계속 보이고 「연결 중」 표시가 남는다(다음 `probe` 는 전과 같이 3틱 뒤). 분류되지 않은 영구 오류는 [message] 를 알린다.
     */
    fun probeFailed(ui: HubUi, classified: Phase?, transient: Boolean, message: String?): HubUi {
        val phase = classified ?: ui.phase
        return ui.copy(phase = phase, connecting = transient || phase is Phase.Stored, notice = if (transient || classified != null) ui.notice else message)
    }

    /** 세션이 필요한 동작(보내기 · 첨부 · 참여 요청 · 읽음 올리기 …)을 해도 되나: 릴레이가 이 기기·세션을 확인한 `Ready` 에서만. */
    fun live(phase: Phase): Boolean = phase is Phase.Ready
}
