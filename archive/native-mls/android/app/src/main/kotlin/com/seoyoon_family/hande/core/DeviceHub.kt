// 기기 허브(#338 B1): Rust 코어(`MlsLobby` · `MlsRoom`)를 묶는 Kotlin 쪽 단일 작성자. HOST-CONTRACT §1 의 호스트 몫만 한다 —
// 호출 주기(전면 4 s poll) · 영속 어댑터(`FileLobbyStore`/`FileRoomStore` + Keystore 봉인) · 전송(`OkHttpTransport`) · 메시지 기록 · 화면 상태.
// 신원: 로비 상태가 곧 시드 — 방은 전부 `MlsRoom.adopt(identity, room, lobby.seedState(), …)` 로 만든다(서명키 하나, §2b).
// 참여 흐름: `replenish(8)` 로 로비 키를 올려 두면 운영자(steward 봇)가 초대 → `welcomes()` 에 방이 뜨면 `adopt(seq - 1)` → `poll` 이 join.
package com.seoyoon_family.hande.core

import android.content.Context
import android.util.Log
import com.seoyoon_family.hande.host.FileLobbyStore
import com.seoyoon_family.hande.host.FileRoomStore
import com.seoyoon_family.hande.mls.MlsLobby
import com.seoyoon_family.hande.mls.MlsRoom
import com.seoyoon_family.hande.mls.RoomEvent
import com.seoyoon_family.hande.mls.RoomException
import com.seoyoon_family.hande.mls.SendResult
import com.seoyoon_family.hande.ui.Strings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

sealed interface Phase {
    /** 릴레이 주소·이름이 없다. */
    data object Setup : Phase
    data object Starting : Phase
    /** 릴레이가 403 `device_subject_mismatch` — 운영자 등록 대기. `json` 은 등록 JSON(비밀 없음). */
    data class WaitingEnrollment(val json: String) : Phase
    /** 401 — 세션 값이 없거나 만료. */
    data object NeedsLogin : Phase
    data object Ready : Phase
    data class Fatal(val message: String) : Phase
}

/** `unread`(#571 후속): 마지막 글이 남의 글이고 본 위치 `max(Settings.readSeq, MlsRoom.readSeq())` 보다 뒤 — `Unread.isUnread`. */
data class RoomUi(val room: String, val joined: Boolean, val halted: String?, val messages: List<MessageUi>, val unread: Boolean)

data class HubUi(
    val phase: Phase = Phase.Setup,
    val deviceId: String? = null,
    val fingerprint: String? = null,
    val keyCustody: String? = null,
    val rooms: List<RoomUi> = emptyList(),
    val lobbyLive: Int? = null,
    val lobbyMax: Int? = null,
    val connecting: Boolean = false,
    val notice: String? = null,
)

class DeviceHub(context: Context, val settings: Settings, private val sealer: KeystoreSealer) {
    private val dir = File(context.filesDir, "mls").apply { mkdirs() }
    private val transport = OkHttpTransport()
    private val mutex = Mutex()
    private val _ui = MutableStateFlow(HubUi(phase = if (settings.isConfigured) Phase.Starting else Phase.Setup))
    val ui: StateFlow<HubUi> = _ui

    /** 정식 메시지 저장소(B2) — 프로세스에 하나. 내 글 판정은 읽을 때 actor 로(같은 사람의 다른 기기 글도 내 글). */
    private val db = MessageDb(context) { settings.deviceId }
    private var lobby: MlsLobby? = null
    private var lobbyStore: FileLobbyStore? = null
    private val rooms = LinkedHashMap<String, Handle>()
    private var loop: Job? = null
    private var ticks = 0

    private inner class Handle(val name: String) {
        var halted: String? = null
        val store = FileRoomStore(
            dir, name, seal = sealer::seal, open = sealer::open,
            onEvent = { e -> if (e is RoomEvent.Joined) notice("$name 대화방에 참여했습니다") },
            onMessage = { seq, sender, clientId, plaintext ->
                // file-v2 평문은 파일 키가 든 설명자 — 글로 저장·표시하지 않는다(#499, FileV2.classify).
                // status-v1(#560): 에이전트 작업 상태 한 줄은 저장하지 않는다(임시 말풍선 — 표시는 후속).
                val row = FileV2.classify(clientId, plaintext) ?: return@FileRoomStore
                if (row.kind == MessageSchema.KIND_UNDECRYPTABLE) Log.w(TAG, "$name seq $seq: file-v2 message rejected")
                db.insert(name, seq, sender, clientId, row.kind, row.body, row.attachment)
            },
        )
        lateinit var room: MlsRoom
        init { db.upsertRoom(name) }
        fun ui(): RoomUi {
            val messages = db.messages(name)
            // 릴레이가 아는 같은 사람(actor)의 읽음 위치(#571 B) — 재시작 뒤 첫 poll 전에는 0 이므로 로컬 값과 max 로 합친다(웹 mergeRelayRead).
            val relayRead = runCatching { room.readSeq() }.getOrDefault(0L)
            val unread = Unread.isUnread(messages, maxOf(settings.readSeq(name), relayRead))
            return RoomUi(name, runCatching { room.syncState().joined }.getOrDefault(false), halted ?: store.haltReason(), messages, unread)
        }
    }

    /** 설정 화면이 저장한 뒤 또는 앱 시작 때. 같은 scope 에서 한 번만. */
    fun start(scope: CoroutineScope) {
        if (loop != null || !settings.isConfigured) return
        _ui.update { it.copy(phase = Phase.Starting) }
        loop = scope.launch(Dispatchers.IO) {
            try {
                boot()
            } catch (e: Throwable) {
                _ui.update { it.copy(phase = Phase.Fatal(e.message ?: e.toString())) }
                return@launch
            }
            while (isActive) {
                tick()
                delay(POLL_MS)
            }
        }
    }

    private suspend fun boot() = mutex.withLock {
        val identity = settings.deviceId ?: error("no identity")
        val base = settings.relayUrl ?: error("no relay url")
        Log.i(TAG, "boot: identity=$identity relay=${base.substringAfter("://").substringBefore('/')}")
        val ls = FileLobbyStore(File(dir, "lobby"), seal = sealer::seal, open = sealer::open)
        lobbyStore = ls
        val slot = ls.load()
        Log.i(TAG, "boot: lobby slot ${if (slot == null) "absent → new" else "present(${slot.published.size} published) → import"}")
        val l = slot?.let { MlsLobby.`import`(identity, it, base, transport, ls) } ?: MlsLobby(identity, base, transport, ls)
        lobby = l
        Log.i(TAG, "boot: lobby ready")
        db.migrateLegacy(dir, sealer::open) // B1 봉인 JSONL → messages.db(한 번)
        for (f in dir.listFiles { _, n -> n.endsWith(".state") }.orEmpty()) {
            val name = f.name.removeSuffix(".state")
            val h = Handle(name)
            val (state, sync) = h.store.load() ?: continue
            h.room = MlsRoom.`import`(identity, name, state, sync, base, transport, h.store)
            rooms[name] = h
        }
        applyAccessToken()
        Log.i(TAG, "boot: rooms=${rooms.size} token=${if (settings.accessToken == null) "none" else "set"}")
        val fp = sha256Hex(l.publicKey())
        Log.i(TAG, "boot: fingerprint ${fp.take(12)}… → probe")
        _ui.update { it.copy(deviceId = identity, fingerprint = fp, keyCustody = sealer.describe(), rooms = rooms.values.map { r -> r.ui() }) }
        probe()
    }

    private fun applyAccessToken() {
        val token = settings.accessToken
        lobby?.setAccessToken(token)
        rooms.values.forEach { it.room.setAccessToken(token) }
    }

    /** 릴레이와 첫 접촉: 로비 상태로 등록·세션 여부를 가른다(iOS `waitingOperator` 와 같은 규칙). */
    private fun probe() {
        val l = lobby ?: return
        Log.i(TAG, "probe: lobby.status()")
        try {
            val s = l.status()
            Log.i(TAG, "probe: ok live=${s.live} max=${s.max}")
            _ui.update { it.copy(phase = Phase.Ready, lobbyLive = s.live.toInt(), lobbyMax = s.max.toInt(), connecting = false, notice = null) }
        } catch (e: RoomException) {
            Log.w(TAG, "probe: $e")
            val transient = e is RoomException.Relay && e.transient
            _ui.update { it.copy(phase = classify(e) ?: it.phase, connecting = transient, notice = if (transient || classify(e) != null) it.notice else e.message) }
        }
    }

    /**
     * 릴레이 응답 → 화면 단계. 봉투(`relay error <status>: <code>`)는 코드로, 봉투 없는 상태(`relay status <n>`)는 CF Access 엣지다:
     * 302(로그인 리다이렉트)·401·403(허용되지 않은 신원) → 세션 값 입력. 403 `device_subject_mismatch` 는 릴레이 본체(등록 대기).
     */
    private fun classify(e: RoomException): Phase? = when {
        e is RoomException.Relay && e.transient -> null
        e is RoomException.Relay && "device_subject_mismatch" in e.reason -> Phase.WaitingEnrollment(enrollmentJson())
        e is RoomException.Relay && EDGE_AUTH.containsMatchIn(e.reason) -> Phase.NeedsLogin
        else -> null
    }

    private suspend fun tick() = mutex.withLock {
        val l = lobby ?: return@withLock
        ticks += 1
        if (_ui.value.phase !is Phase.Ready) {
            if (ticks % 3 == 0) probe()
            return@withLock
        }
        var connecting = false
        for (h in rooms.values.toList()) {
            try {
                h.room.poll()
            } catch (e: RoomException) {
                when {
                    e is RoomException.Relay && e.transient -> connecting = true
                    e is RoomException.Relay && "room_closed" in e.reason -> h.halted = "room_closed"
                    else -> { Log.w(TAG, "poll ${h.name}: $e"); classify(e)?.let { p -> _ui.update { it.copy(phase = p) } }; notice("${h.name}: ${e.message}") }
                }
            }
        }
        // 로비 Welcome → 모르는 방이면 로비 상태로 받아들인다(HOST-CONTRACT §2b).
        try {
            for (w in l.welcomes()) {
                if (rooms.containsKey(w.room)) continue
                val h = Handle(w.room)
                h.room = MlsRoom.adopt(l.identity(), w.room, l.seedState(), w.seq - 1, settings.relayUrl!!, transport, h.store)
                h.room.setAccessToken(settings.accessToken)
                rooms[w.room] = h
                h.room.poll()
                replenish(l)
            }
        } catch (e: RoomException) {
            if (e is RoomException.Relay && e.transient) connecting = true else classify(e)?.let { p -> _ui.update { it.copy(phase = p) } }
        }
        if (ticks % REPLENISH_EVERY == 1) runCatching { replenish(l) }
        _ui.update { it.copy(rooms = rooms.values.map { r -> r.ui() }, connecting = connecting) }
    }

    private fun replenish(l: MlsLobby) {
        val r = l.replenish(LOBBY_TARGET.toUInt())
        _ui.update { it.copy(lobbyLive = r.live.toInt(), lobbyMax = r.max.toInt()) }
    }

    // ---- 화면이 부르는 것 ----

    /** 「참여 요청」: 로비 키를 올려 운영자가 초대할 수 있게 한다. */
    fun requestJoin(scope: CoroutineScope) = scope.launch(Dispatchers.IO) {
        mutex.withLock {
            val l = lobby ?: return@withLock
            try {
                replenish(l)
                notice("참여 요청을 올렸습니다. 운영자가 초대하면 대화방이 나타납니다.")
            } catch (e: RoomException) { classify(e)?.let { p -> _ui.update { it.copy(phase = p) } } ?: notice(e.message ?: "오류") }
        }
    }

    fun send(scope: CoroutineScope, room: String, text: String) = scope.launch(Dispatchers.IO) {
        val h = mutex.withLock { rooms[room] } ?: return@launch
        try {
            val r = mutex.withLock { h.room.send(text.toByteArray(Charsets.UTF_8)) }
            when (r) {
                is SendResult.Sent -> db.insert(room, r.seq, h.room.identity(), r.clientId, MessageDb.KIND_TEXT, text, null)
                is SendResult.Queued -> notice("연결되면 보냅니다")
                is SendResult.AlreadyDelivered -> {}
            }
            _ui.update { it.copy(rooms = rooms.values.map { r2 -> r2.ui() }) }
        } catch (e: RoomException) {
            notice(if (e is RoomException.Relay && e.transient) "연결 중입니다…" else (e.message ?: "전송 안 됨"))
        }
    }

    /**
     * 방을 보고 있다(열 때 · 보는 중 새 글, #571 후속 — 웹 `room.js markRead` 와 같은 시점): 마지막 seq 를 이 기기에 적고(`Settings`, 줄어들지 않음)
     * `POST /v2/rooms/{room}/read` 로 올린다(`MlsRoom.markRead` — 릴레이가 actor 단위로 보관, 이미 아는 위치 이하면 보내지 않음).
     * 안내 신호라 실패(옛 릴레이 404 는 코어가 무시 · 410/403/전송 실패)는 로그만 남긴다. MLS 커서·ack 와 무관.
     */
    fun markRead(scope: CoroutineScope, room: String) = scope.launch(Dispatchers.IO) {
        mutex.withLock {
            val h = rooms[room] ?: return@withLock
            val seq = Unread.latestSeq(db.messages(room))
            if (seq <= 0L) return@withLock
            settings.markRead(room, seq)
            runCatching { h.room.markRead(seq) }.onFailure { e -> Log.w(TAG, "markRead $room seq $seq: $e") }
            _ui.update { it.copy(rooms = rooms.values.map { r -> r.ui() }) }
        }
    }

    /** 설정 저장 뒤(세션 값 포함) 다시 접촉. */
    fun reconfigure(scope: CoroutineScope) = scope.launch(Dispatchers.IO) {
        mutex.withLock { applyAccessToken(); _ui.update { it.copy(phase = Phase.Starting) }; probe() }
    }

    fun retryEnrollment(scope: CoroutineScope) = reconfigure(scope)

    // ---- 가족 로그인(B2, iOS §12-C A) ----

    /** 「Google 계정으로 로그인」: 새 `state` 를 만들어 두고 시스템 브라우저로 릴레이 로그인 주소를 연다. 실패는 알림 한 줄. */
    fun beginLogin(context: Context) {
        val relay = settings.relayUrl
        val state = AppLogin.makeState()
        val url = relay?.let { AppLogin.loginUrl(it, state) }
        if (url == null) { notice(Strings.loginFailure(AppLogin.Failure.BadRelayUrl)); return }
        settings.pendingLoginState = state
        try {
            LoginLauncher.open(context, url)
        } catch (e: AppLogin.Failure) {
            settings.pendingLoginState = null
            notice(Strings.loginFailure(e))
        }
    }

    /** 콜백 `hande://auth#jwt=…&state=…`: 내 `state` 인지 확인하고 세션 값으로 저장한 뒤 다시 접촉한다. 모르는 콜백은 무시(알림만). */
    fun completeLogin(scope: CoroutineScope, callback: String) {
        val expected = settings.pendingLoginState ?: ""
        val jwt = try {
            AppLogin.tokenFromCallback(callback, expected)
        } catch (e: AppLogin.Failure) {
            Log.w(TAG, "login callback rejected: ${e.message}")
            notice(Strings.loginFailure(e))
            return
        }
        settings.pendingLoginState = null
        settings.accessToken = jwt
        Log.i(TAG, "login: session accepted via app-login → probe")
        reconfigure(scope)
    }

    fun clearNotice() = _ui.update { it.copy(notice = null) }

    /** 등록 JSON — 운영자 CLI(`-enroll-first`/`-add-device`) 입력과 키가 같다(iOS `EnrollmentRequest`). 비밀 없음. */
    fun enrollmentJson(): String {
        val l = lobby ?: return ""
        val id = l.identity()
        val pub = l.publicKey()
        return JSONObject()
            .put("actor", id.substringBefore('-'))
            .put("device_id", id)
            .put("fingerprint", sha256Hex(pub))
            .put("signing_key", pub.joinToString("") { "%02x".format(it) })
            .put("subject", "")
            .toString(2)
    }

    private fun notice(text: String) = _ui.update { it.copy(notice = text) }

    private companion object {
        const val TAG = "hande.hub"
        /** 엣지 인증 실패 모양: `relay status 301|302|303|307|308|401|403` · `relay error 401: …`. */
        val EDGE_AUTH = Regex("relay (status (30[12378]|401|403)\\b|error 401\\b)")
        const val POLL_MS = 4_000L
        const val LOBBY_TARGET = 8
        const val REPLENISH_EVERY = 15 // ≈ 1분
        fun sha256Hex(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
