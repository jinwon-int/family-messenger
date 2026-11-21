// 보내는 글 말풍선(#837, iOS `AppModel.outgoing` 과 같은 결): 보내기를 누르는 즉시 「보내는 중…」 말풍선을 올리고, 허브(`DeviceHub`)가
// 뒤에서 누른 순서대로 하나씩 보낸다. 릴레이가 받으면 그 글은 이력 행(`MessageDb`)이 되고 여기서 빠진다 · 실패하면 「전송 안 됨」 + 다시 보내기.
// 코어가 409 cas_mismatch 로 재시도 큐에 넣은 글(`SendResult.Queued`)은 「보내는 중」으로 남는다. 코어는 다음 `poll` 의 `after_page` 에서
// 큐를 앞에서부터 다시 보내고 항목마다 이벤트 하나를 낸다(`Replayed` · `Conflict`(다시 뒤로) · `AlreadyDelivered` · `Dropped`). 다시 보낼 때
// client_id 가 새로 정해지므로 이벤트는 client_id 가 아니라 **큐 순서**로 맞춘다 — 글 항목만 따로 같은 순서의 큐로 들고 있고, file-v2 첨부
// (`file-v2-` client_id)의 이벤트는 건너뛴다. `after_page` 가 도중에 오류로 끝나면 남은 항목은 코어에서 사라지므로 「전송 안 됨」으로 바꾼다.
// 메모리에만 있다(코어의 재시도 큐도 메모리) — 앱을 다시 시작하면 둘 다 없으니 「보내는 중」 유령이 남지 않는다. android.* 없음(JVM 단위 테스트).
package com.seoyoon_family.hande.core

/** 화면에 보일 아직 확정되지 않은 내 글. `failed` 면 「전송 안 됨」 + 다시 보내기, 아니면 「보내는 중…」(코어 재시도 큐에 있는 글 포함). */
data class OutgoingUi(val id: Long, val text: String, val failed: Boolean = false)

class OutgoingBubbles {
    private enum class State { WAITING, SENDING, QUEUED, FAILED }
    private class Item(val id: Long, val room: String, val text: String, var state: State)
    /** 한 번의 `poll`: 시작할 때 큐에 있던 글 수 · 그중 이벤트로 처리된 수 · 이 poll 에서 본 재시도 이벤트 수(첨부 포함). */
    private class Round(val due: Int) {
        var processed = 0
        var events = 0
    }

    private val lock = Any()
    private var nextId = 1L
    private val items = ArrayList<Item>()
    private val replay = HashMap<String, ArrayDeque<Item>>()
    private val rounds = HashMap<String, Round>()

    /** 누른 글을 맨 뒤에 올린다(아직 보내지 않음). 돌려준 id 로 말풍선을 가리킨다. */
    fun add(room: String, text: String): Long {
        synchronized(lock) {
            val id = nextId++
            items += Item(id, room, text, State.WAITING)
            return id
        }
    }

    /** 그 방에서 가장 먼저 누른, 아직 보내지 않은 글을 「보내는 중」으로 바꾸고 돌려준다. 없으면 null. */
    fun takeNext(room: String): Pair<Long, String>? {
        synchronized(lock) {
            val item = items.firstOrNull { it.room == room && it.state == State.WAITING } ?: return null
            item.state = State.SENDING
            return item.id to item.text
        }
    }

    /** 릴레이가 받았다(이력 행이 생겼다) · 이미 릴레이에 있다 — 말풍선을 뺀다. */
    fun sent(id: Long) {
        synchronized(lock) { remove(id) }
    }

    /** 코어 재시도 큐에 들어갔다(409) — 「보내는 중」으로 남고 다음 poll 의 이벤트를 기다린다. */
    fun queued(room: String, id: Long) {
        synchronized(lock) {
            val item = items.firstOrNull { it.id == id && it.room == room } ?: return
            item.state = State.QUEUED
            replay.getOrPut(room) { ArrayDeque() }.addLast(item)
        }
    }

    /** 보내지 못했다 — 「전송 안 됨」. */
    fun failed(id: Long) {
        synchronized(lock) { items.firstOrNull { it.id == id }?.state = State.FAILED }
    }

    /** 보내는 도중 끝났는데(취소·예상 밖 오류) 아직 「보내는 중」이면 「전송 안 됨」으로. 바꿨으면 참. */
    fun failIfSending(id: Long): Boolean {
        synchronized(lock) {
            val item = items.firstOrNull { it.id == id && it.state == State.SENDING } ?: return false
            item.state = State.FAILED
            return true
        }
    }

    /** 「다시 보내기」: 실패한 글을 빼고 같은 글을 새로 맨 뒤에 올린다(iOS `retry` 와 같음). 새 id, 실패한 글이 아니면 null. */
    fun retry(room: String, id: Long): Long? {
        synchronized(lock) {
            val item = items.firstOrNull { it.id == id && it.room == room && it.state == State.FAILED } ?: return null
            items.remove(item)
            val next = nextId++
            items += Item(next, room, item.text, State.WAITING)
            return next
        }
    }

    /** 그 방의 보내는 글(누른 순서). */
    fun list(room: String): List<OutgoingUi> {
        synchronized(lock) {
            return items.filter { it.room == room }.map { OutgoingUi(it.id, it.text, failed = it.state == State.FAILED) }
        }
    }

    // ---- 코어 재시도 큐의 이벤트(방의 `poll` 안에서 온다) ----

    /** 방 `poll` 직전. */
    fun beginPoll(room: String) {
        synchronized(lock) { rounds[room] = Round(replay[room]?.size ?: 0) }
    }

    /** `Replayed`: 큐 맨 앞 글이 새 epoch 로 나갔다 — 그 글을 돌려준다(호출자가 이력 행으로). 첨부·짝 없음이면 null. */
    fun replayed(room: String, clientId: String): String? {
        synchronized(lock) {
            val item = popHead(room, clientId) ?: return null
            items.remove(item)
            return item.text
        }
    }

    /** `Conflict`: 또 409 — 맨 앞 글을 맨 뒤로(코어 `push_back` 과 같은 순서). attempt 1 은 처음 보낼 때의 것이라 큐와 무관하다. */
    fun conflict(room: String, clientId: String, attempt: Int) {
        if (attempt <= 1) return
        synchronized(lock) {
            val item = popHead(room, clientId) ?: return
            replay.getOrPut(room) { ArrayDeque() }.addLast(item)
        }
    }

    /** `AlreadyDelivered`: 릴레이에 이미 있다 — 맨 앞 글의 말풍선을 뺀다. */
    fun alreadyDelivered(room: String, clientId: String) {
        synchronized(lock) {
            val item = popHead(room, clientId) ?: return
            items.remove(item)
        }
    }

    /**
     * `Dropped`(재시도 한도 초과·전송 오류, client_id 없음): 맨 앞 글의 평문 길이와 같으면 그 글을 「전송 안 됨」으로.
     * 길이가 다르면 첨부(file-v2 설명자) 항목이다 — 글 큐는 그대로.
     */
    fun dropped(room: String, bytes: Long) {
        synchronized(lock) {
            val round = rounds[room]
            if (round != null) round.events += 1
            val queue = replay[room] ?: return
            val head = queue.firstOrNull() ?: return
            if (head.text.toByteArray(Charsets.UTF_8).size.toLong() != bytes) return
            queue.removeFirst()
            if (round != null) round.processed += 1
            head.state = State.FAILED
        }
    }

    /**
     * 방 `poll` 직후. 실패했고 이 poll 에서 재시도 이벤트가 하나라도 있었다면(= `after_page` 가 큐를 돌다 오류로 끝났다) 아직 이벤트를
     * 받지 못한 글은 코어 큐에서 사라졌다 — 「전송 안 됨」으로 바꾼다. 이벤트가 없었으면 코어가 큐를 건드리지 않았다(다음 poll 이 보낸다).
     */
    fun endPoll(room: String, failed: Boolean) {
        synchronized(lock) {
            val round = rounds.remove(room) ?: return
            if (!failed || round.events == 0) return
            val queue = replay[room] ?: return
            repeat(round.due - round.processed) {
                val item = queue.removeFirstOrNull() ?: return
                item.state = State.FAILED
            }
        }
    }

    /** 이 기기 지우기. */
    fun clear() {
        synchronized(lock) {
            items.clear()
            replay.clear()
            rounds.clear()
        }
    }

    /** 큐 맨 앞 글(처리 수를 센다). 첨부 client_id 면 이벤트만 세고 null. */
    private fun popHead(room: String, clientId: String): Item? {
        val round = rounds[room]
        if (round != null) round.events += 1
        if (clientId.startsWith(FileV2.CLIENT_PREFIX)) return null
        val item = replay[room]?.removeFirstOrNull() ?: return null
        if (round != null) round.processed += 1
        return item
    }

    private fun remove(id: Long) {
        val item = items.firstOrNull { it.id == id } ?: return
        items.remove(item)
        replay[item.room]?.remove(item)
    }
}
