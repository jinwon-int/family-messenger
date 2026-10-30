// status-v1(#560, archive/native-mls/STATUS-V1.md §3) — 에이전트 작업 상태 임시 말풍선. 웹 `status-v1.js`·iOS `AgentStatusBoard` 와 같은 규칙.
// android.* 없이 JVM 에서 돈다(AgentStatusTest).
package com.seoyoon_family.hande.core

/** 화면에 보일 상태 한 줄(보낸이별 하나). */
data class StatusUi(val sender: String, val text: String)

/**
 * 방 하나의 보낸이별 최신 status. 저장하지 않는다(프로세스 메모리) — 이력·안 읽음·알림 밖.
 * - 새 status → 본문 교체(seq 가 더 작은 옛 status 는 무시)
 * - 같은 보낸이의 일반 메시지(seq 가 더 큼) → 지움. 답보다 앞선 status 가 늦게 와도 다시 뜨지 않는다.
 * - 마지막 갱신 뒤 [TTL_MS] 가 지나면 지움(답 없이 끝난 턴의 안전망).
 * 호출은 DeviceHub 의 mutex 안(poll·ui())에서만 — 별도 잠금이 없다.
 */
class AgentStatusBoard {
    private data class Entry(val text: String, val seq: Long, val at: Long)
    private val bySender = LinkedHashMap<String, Entry>()
    private val lastSeq = HashMap<String, Long>()

    fun apply(sender: String, text: String, seq: Long, nowMs: Long): Boolean {
        val line = text.trim().take(MAX_TEXT)
        if (sender.isEmpty() || line.isEmpty()) return false
        if ((lastSeq[sender] ?: Long.MIN_VALUE) > seq) return false
        val prev = bySender[sender]
        if (prev != null && prev.seq > seq) return false
        bySender[sender] = Entry(line, seq, nowMs)
        return prev?.text != line
    }

    fun clear(sender: String, seq: Long): Boolean {
        if (sender.isEmpty()) return false
        lastSeq[sender] = maxOf(seq, lastSeq[sender] ?: Long.MIN_VALUE)
        val cur = bySender[sender] ?: return false
        if (cur.seq > seq) return false
        bySender.remove(sender)
        return true
    }

    /** 지금 보일 줄들(만료분은 지운다) — seq 오름차순, 대화방 맨 아래에 이 순서로. */
    fun visible(nowMs: Long): List<StatusUi> {
        bySender.entries.removeAll { nowMs - it.value.at > TTL_MS }
        return bySender.entries.sortedBy { it.value.seq }.map { StatusUi(it.key, it.value.text) }
    }

    /** 대화 목록 미리보기 자리에 보일 줄: 가장 최근(seq 최대) status, 없으면 null(오너 2026-10-30). */
    fun listLine(nowMs: Long): String? = visible(nowMs).lastOrNull()?.text

    companion object {
        const val TTL_MS = 5 * 60 * 1000L
        private const val MAX_TEXT = 500
    }
}
