// 대화 목록 순서 동기화(#715 room-order v1 클라이언트 규칙 1·2·4) — 사람(actor) 단위로 릴레이에 둔 순서를 이 기기의 로컬 순서(SharedPreferences)와 맞춘다.
//   1. 목록을 불러올 때(앱 시작·로그인·전면 복귀, 최소 60초 간격) GET. revision > 0 이면 서버 순서를 로컬로 채택(덮어씀).
//      revision == 0 이고 로컬에 사용자 순서가 있으면 PUT base_revision=0 으로 시드(처음 올리는 기기가 기준). 409 면 서버 것을 채택.
//   2. 사용자가 옮기면 로컬에 바로 반영하고 PUT base_revision=<마지막으로 본 revision>. 409 면 서버 것을 채택해 다시 그린다.
//   4. 404(옛 릴레이)면 로컬만 쓰고 이 세션 동안 다시 묻지 않는다. 네트워크 오류·401/403/5xx 는 다음 주기(60초 뒤 틱)에 다시.
// 보탠 것 하나: 올리지 못한 로컬 변경(`pending`, 영속)이 있고 서버 revision 이 마지막으로 본 값 그대로면 GET 뒤 서버 것을 채택하지 않고
//   그 변경을 다시 PUT 한다(오프라인에서 옮긴 순서를 다음 GET 이 지우지 않게). 그 사이 다른 기기가 바꿨으면(revision 이 다름) 서버 것을 채택 — 계약의 충돌 규칙과 같다.
// 세션에서 아직 GET 을 마치지 못했을 때 사용자가 옮기면 PUT 대신 GET 부터(마지막으로 본 revision 이 지난 세션 값이라 409 로 지우지 않게).
// 화면을 막지 않는다: `move` 는 메모리·prefs 만 바꾸고 돌아오며, `sync`/`push`(네트워크)는 허브가 IO 에서 한 번에 하나씩 부른다.
// android.* 없음 — 전송(`http`)·시계(`now`)·저장(`Store`)을 주입받아 JVM 단위 테스트(`RoomOrderSyncTest`)로 돈다.
package com.seoyoon_family.hande.core

class RoomOrderSync(
    private val store: Store,
    private val relayUrl: () -> String?,
    private val device: () -> String?,
    /** 응답이 있으면 상태·본문, 응답이 없으면(연결 실패·타임아웃) null. */
    private val http: (method: String, url: String, body: ByteArray?) -> Reply?,
    /** 단조 시계(ms) — 60초 간격 판정용. */
    private val now: () -> Long,
    private val log: (String) -> Unit = {},
) {
    /** 로컬 영속(`Settings` 가 구현). `roomOrderPending` = 서버에 아직 올리지 못한 로컬 변경이 있다. */
    interface Store {
        var roomOrder: List<String>
        var roomOrderRevision: Long
        var roomOrderPending: Boolean
    }

    class Reply(val status: Int, val body: ByteArray)

    /** GET 뒤 할 일(순수 판정 — `decide`). */
    sealed interface Decision {
        data class Adopt(val snapshot: RoomOrder.Snapshot) : Decision
        data class Push(val rooms: List<String>, val baseRevision: Long) : Decision
        data object Keep : Decision
    }

    private val lock = Any()
    @Volatile private var cached: List<String> = RoomOrder.normalize(store.roomOrder)
    /** 이 세션에 물어야 할 GET 이 있다(시작·로그인·전면 복귀·일시 실패). */
    private var wanted = true
    /** 다음 한 번은 60초 간격을 보지 않는다(시작·로그인). */
    private var force = true
    private var lastAttemptAt: Long? = null
    /** 이 세션에 GET 을 한 번이라도 마쳤다(마지막으로 본 revision 이 이 세션 값). */
    private var fetched = false
    /** 404 — 이 세션 동안 로컬만. */
    @Volatile private var unsupported = false
    /** 로컬 순서 세대 — PUT 이 도는 동안 사용자가 또 옮겼는지 본다. */
    private var gen = 0L

    /** 순서가 바뀌었다(채택·사용자 이동) — 허브가 목록을 다시 그린다. 잠금 밖에서 부른다. */
    var onChange: ((List<String>) -> Unit)? = null

    /** 지금 로컬 순서(표시용). */
    val order: List<String> get() = cached

    /** 릴레이 동기화를 쓰는가(404 를 받기 전까지 true) — 편집 안내 문구가 고른다. */
    val synced: Boolean get() = !unsupported

    /** 규칙 1 의 계기(전면 복귀·목록 새로고침). 60초 간격은 `isDue` 가 본다. */
    fun request() = synchronized(lock) { wanted = true }

    /** 새 세션(다시 설정·로그인): 404 판정을 지우고 바로 한 번 묻는다. */
    fun resetSession() = synchronized(lock) {
        unsupported = false; wanted = true; force = true; fetched = false; lastAttemptAt = null
    }

    /** 허브 틱이 본다: 물을 것(계기 또는 올리지 못한 변경)이 있고 60초가 지났는가. 네트워크 없음. */
    fun isDue(): Boolean = synchronized(lock) { dueLocked() }

    private fun dueLocked(): Boolean {
        if (unsupported || !(wanted || store.roomOrderPending)) return false
        val last = lastAttemptAt ?: return true
        return force || now() - last >= MIN_INTERVAL_MS
    }

    /**
     * 사용자가 옮겼다(규칙 2의 앞 절반): 정규화해 로컬에 바로 저장하고 새 순서를 돌려준다. 네트워크 없음 — 허브가 이어서 `push` 를 IO 에서 부른다.
     */
    fun move(next: List<String>): List<String> {
        val n = RoomOrder.normalize(next)
        synchronized(lock) {
            store.roomOrder = n
            store.roomOrderPending = true
            cached = n
            gen++
        }
        onChange?.invoke(n)
        return n
    }

    /** 기기 지우기: 메모리 상태도 처음으로(prefs 는 `Settings.wipe` 가 지운다). */
    fun clear() = synchronized(lock) {
        cached = emptyList(); gen++; unsupported = false; wanted = true; force = true; fetched = false; lastAttemptAt = null
    }

    /** 규칙 1: 때가 됐으면 GET 하고 채택·시드·재전송을 정한다. 블로킹 — 허브가 IO 에서 한 번에 하나씩 부른다. */
    fun sync() {
        synchronized(lock) {
            if (!dueLocked()) return
        }
        fetchNow()
    }

    /** 규칙 2 의 뒤 절반: 올리지 못한 로컬 변경을 PUT. 이 세션에 아직 GET 전이면 GET 부터(그 뒤 판정이 PUT 을 정한다). 블로킹. */
    fun push() {
        val start = synchronized(lock) {
            if (unsupported || !store.roomOrderPending) return
            if (!fetched) null else Triple(cached, store.roomOrderRevision, gen)
        }
        if (start == null) { fetchNow(); return }
        put(start.first, start.second, start.third)
    }

    private fun fetchNow() {
        val relay = relayUrl() ?: return
        val dev = device() ?: return
        val url = RoomOrder.getUrl(relay, dev) ?: return
        synchronized(lock) { lastAttemptAt = now(); force = false }
        val r = http("GET", url, null)
        var changed: List<String>? = null
        val decision = synchronized(lock) {
            when {
                r == null -> { log("room-order: GET no response — retry later"); null }
                r.status == 404 -> { unsupported = true; wanted = false; log("room-order: relay has no /v2/me/room-order — local only"); null }
                r.status != 200 -> { log("room-order: GET ${r.status} — retry later"); null }
                else -> {
                    wanted = false
                    val snap = RoomOrder.parseSnapshot(String(r.body, Charsets.UTF_8))
                    if (snap == null) { log("room-order: GET 200 unreadable — ignored"); null } else {
                        fetched = true
                        when (val d = decide(snap, cached, store.roomOrderPending, store.roomOrderRevision)) {
                            is Decision.Adopt -> { changed = adoptLocked(d.snapshot); null }
                            is Decision.Push -> { store.roomOrderPending = true; Triple(d.rooms, d.baseRevision, gen) }
                            Decision.Keep -> { store.roomOrderRevision = 0L; store.roomOrderPending = false; null }
                        }
                    }
                }
            }
        }
        changed?.let { onChange?.invoke(it) }
        if (decision != null) put(decision.first, decision.second, decision.third)
    }

    /** PUT 하나(+ 그 사이 사용자가 또 옮겼으면 새 revision 으로 이어서, 최대 3번). */
    private fun put(rooms0: List<String>, base0: Long, gen0: Long) {
        val relay = relayUrl() ?: return
        val dev = device() ?: return
        val url = RoomOrder.putUrl(relay) ?: return
        var rooms = rooms0
        var base = base0
        var sentGen = gen0
        repeat(MAX_PUT_CHAIN) {
            synchronized(lock) { lastAttemptAt = now() }
            val r = http("PUT", url, RoomOrder.putBody(dev, rooms, base).toByteArray(Charsets.UTF_8))
            var changed: List<String>? = null
            val again = synchronized(lock) {
                when {
                    r == null -> { log("room-order: PUT no response — retry later"); false }
                    r.status == 200 -> {
                        val snap = RoomOrder.parseSnapshot(String(r.body, Charsets.UTF_8))
                        if (snap == null) { wanted = true; log("room-order: PUT 200 unreadable — refetch"); false }
                        else {
                            store.roomOrderRevision = snap.revision
                            if (gen == sentGen) { store.roomOrderPending = false; false }
                            else { rooms = cached; base = snap.revision; sentGen = gen; true } // 도는 사이 또 옮겼다
                        }
                    }
                    r.status == 409 -> {
                        val snap = RoomOrder.parseSnapshot(String(r.body, Charsets.UTF_8))
                        if (snap == null) { wanted = true; force = true; log("room-order: 409 unreadable — refetch") }
                        else { log("room-order: 409 revision_conflict → adopt server revision ${snap.revision}"); changed = adoptLocked(snap) }
                        false
                    }
                    r.status == 404 -> { unsupported = true; log("room-order: PUT 404 — local only"); false }
                    r.status == 400 -> { store.roomOrderPending = false; log("room-order: PUT 400 — kept local, not retried"); false }
                    else -> { log("room-order: PUT ${r.status} — retry later"); false }
                }
            }
            changed?.let { onChange?.invoke(it) }
            if (!again) return
        }
    }

    /** 서버 순서를 로컬로(덮어씀). 바뀌었으면 새 순서, 같으면 null. */
    private fun adoptLocked(snap: RoomOrder.Snapshot): List<String>? {
        val before = cached
        store.roomOrder = snap.rooms
        store.roomOrderRevision = snap.revision
        store.roomOrderPending = false
        cached = snap.rooms
        gen++
        return if (before == snap.rooms) null else snap.rooms
    }

    companion object {
        const val MIN_INTERVAL_MS = 60_000L
        private const val MAX_PUT_CHAIN = 3

        /**
         * GET 결과 → 할 일(규칙 1 + 위 「보탠 것」). `pending` 이고 서버 revision 이 마지막으로 본 값이면 로컬 변경을 그 revision 으로 다시 올린다.
         * 아니면 revision > 0 → 채택. revision == 0 → 로컬에 순서가 있으면 base 0 으로 시드, 없으면 할 일 없음.
         */
        fun decide(server: RoomOrder.Snapshot, local: List<String>, pending: Boolean, lastRevision: Long): Decision = when {
            pending && server.revision == lastRevision && (server.revision > 0 || local.isNotEmpty()) -> Decision.Push(local, lastRevision)
            server.revision > 0 -> Decision.Adopt(server)
            local.isNotEmpty() -> Decision.Push(local, 0L)
            else -> Decision.Keep
        }
    }
}
