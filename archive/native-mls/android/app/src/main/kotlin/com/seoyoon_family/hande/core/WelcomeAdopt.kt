// 로비 Welcome 을 받아들일지 판정(#616, 순수 로직 — android.* 없이 JVM 단위 테스트). 화면·코어 연결은 `DeviceHub.lobbyAux`.
//
// `GET /v2/lobby/welcomes` 는 이 기기가 아직 읽고 지나가지(ack) 않은 Welcome 을 방마다 하나씩 준다. 모르는 방이면 로비 상태로 방을
// 만들어 받아들인다(HOST-CONTRACT §2b). 이미 아는 방이면 보통은 그 방의 `poll` 이 알아서 join 하지만, **한 번 실패한 방은 그렇지
// 않다**: 코어 `poll` 은 join 이 거부된 Welcome 을 지나가고(`RoomEvent.Rejected`) 다시 보지 않으며, 방의 엔진 상태는 처음 받아들일
// 때의 로비 상태 사본이라 그 뒤에 만든 로비 키의 비밀이 없다 — 운영자가 내보냈다가 다시 초대해도 그 방의 `poll` 로는 열 수 없다.
// 그래서 「읽고 지나갔는데 참여하지 못한」 Welcome 은 지금의 로비 상태로 방을 다시 만들어 한 번 더 받아들인다(iOS #521 과 같은 뜻).
// 같은 Welcome 은 **한 번만** — 다시 받아들이기는 방의 커서를 Welcome 앞으로 되감으므로, 열리지 않는 Welcome 이면 그 뒤 이력을
// 통째로 다시 읽는다. 해 본 seq 를 기기에 저장해(`encodeRetried`) 재시작 뒤에도 되풀이하지 않는다. 다시 초대받으면 seq 가 커져
// 한 번 더 해 본다.
package com.seoyoon_family.hande.core

object WelcomeAdopt {
    enum class Decision {
        /** 모르는 방 — 로비 상태로 방을 만들어 받아들인다. */
        ADOPT,

        /** 아는 방인데 이 Welcome 을 지나가고도 참여하지 못했다 — 지금의 로비 상태로 방을 다시 만든다. */
        READOPT,

        /** 아무것도 하지 않는다(이미 참여 · 정지 · 그 방의 `poll` 이 아직 Welcome 에 닿지 않음 · 이번 실행에서 이미 다시 해 봄). */
        SKIP,
    }

    /**
     * @param known 이 방의 핸들이 이미 있다
     * @param joined 그 방에 참여해 있다(`RoomSyncState.joined`)
     * @param halted 그 방이 정지돼 있다(정지는 최종 — 건드리지 않는다)
     * @param cursor 그 방에서 읽은 위치(`RoomSyncState.cursor`), 모르면 null
     * @param welcomeSeq 목록의 Welcome seq
     * @param retriedSeq 이 방에 다시 받아들이기를 해 본 가장 큰 Welcome seq(기기에 저장된 값, 없으면 null)
     */
    fun decide(known: Boolean, joined: Boolean, halted: Boolean, cursor: Long?, welcomeSeq: Long, retriedSeq: Long?): Decision = when {
        !known -> Decision.ADOPT
        joined || halted -> Decision.SKIP
        // 위치를 모르거나 아직 Welcome 앞이다 — 그 방의 `poll` 이 제 상태로 join 한다(막 받아들인 방 · 첫 poll 이 일시 오류였던 방).
        cursor == null || cursor < welcomeSeq -> Decision.SKIP
        retriedSeq != null && retriedSeq >= welcomeSeq -> Decision.SKIP
        else -> Decision.READOPT
    }

    // ---- 해 본 Welcome 의 저장 형식: 한 줄에 `방|seq`(방 이름은 식별자 문자집합이라 구분자와 겹치지 않는다) ----

    /** 저장된 글 → 방별 seq. 모양이 어긋난 줄·음수는 버린다(모르는 값 때문에 다시 받아들이기를 영영 막지 않게). 같은 방이 여러 번이면 큰 값. */
    fun decodeRetried(text: String?): Map<String, Long> {
        val out = LinkedHashMap<String, Long>()
        for (line in text.orEmpty().lineSequence()) {
            val cut = line.lastIndexOf('|')
            if (cut <= 0) continue
            val room = line.substring(0, cut)
            val seq = line.substring(cut + 1).toLongOrNull() ?: continue
            if (seq < 0) continue
            out[room] = maxOf(out[room] ?: seq, seq)
        }
        return out
    }

    /** 방 이름 순으로 적는다(같은 내용이면 같은 글 — 바뀌지 않았으면 쓰지 않으려고). */
    fun encodeRetried(retried: Map<String, Long>): String =
        retried.entries.sortedBy { it.key }.joinToString("\n") { "${it.key}|${it.value}" }

    /** 더 볼 일이 없는 기록을 걷어낸다: 아는 방이면서 아직 참여하지 못한 방([waiting])의 것만 남긴다(참여했거나 없어진 방은 지운다). */
    fun pruneRetried(retried: Map<String, Long>, waiting: Set<String>): Map<String, Long> = retried.filterKeys { it in waiting }
}
