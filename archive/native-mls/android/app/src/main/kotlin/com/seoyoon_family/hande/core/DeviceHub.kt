// 기기 허브(#338 B1): Rust 코어(`MlsLobby` · `MlsRoom`)를 묶는 Kotlin 쪽 단일 작성자. HOST-CONTRACT §1 의 호스트 몫만 한다 —
// 호출 주기(전면 4 s poll) · 영속 어댑터(`FileLobbyStore`/`FileRoomStore` + Keystore 봉인) · 전송(`JdkHttpTransport`) · 메시지 기록 · 화면 상태.
// 신원: 로비 상태가 곧 시드 — 방은 전부 `MlsRoom.adopt(identity, room, lobby.seedState(), …)` 로 만든다(서명키 하나, §2b).
// 참여 흐름: `replenish(8)` 로 로비 키를 올려 두면 운영자(steward 봇)가 초대 → `welcomes()` 에 방이 뜨면 `adopt(seq - 1)` → `poll` 이 join.
package com.seoyoon_family.hande.core

import android.content.Context
import com.seoyoon_family.hande.host.FileLobbyStore
import com.seoyoon_family.hande.host.FileRoomStore
import com.seoyoon_family.hande.host.JdkHttpTransport
import com.seoyoon_family.hande.mls.MlsLobby
import com.seoyoon_family.hande.mls.MlsRoom
import com.seoyoon_family.hande.mls.RoomEvent
import com.seoyoon_family.hande.mls.RoomException
import com.seoyoon_family.hande.mls.SendResult
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

data class RoomUi(val room: String, val joined: Boolean, val halted: String?, val messages: List<MessageUi>)

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
    private val transport = JdkHttpTransport()
    private val mutex = Mutex()
    private val _ui = MutableStateFlow(HubUi(phase = if (settings.isConfigured) Phase.Starting else Phase.Setup))
    val ui: StateFlow<HubUi> = _ui

    private var lobby: MlsLobby? = null
    private var lobbyStore: FileLobbyStore? = null
    private val rooms = LinkedHashMap<String, Handle>()
    private var loop: Job? = null
    private var ticks = 0

    private inner class Handle(val name: String) {
        val log = MessageLog(File(dir, "$name.messages"), sealer::seal, sealer::open)
        var halted: String? = null
        val store = FileRoomStore(
            dir, name, seal = sealer::seal, open = sealer::open,
            onEvent = { e -> if (e is RoomEvent.Joined) notice("$name 대화방에 참여했습니다") },
            onMessage = { seq, sender, clientId, plaintext ->
                val attachment = clientId.startsWith("file-v1-")
                log.append(MessageUi(seq, sender, if (attachment) "📎 첨부(${plaintext.size} B)" else String(plaintext, Charsets.UTF_8), mine = false, attachment = attachment))
            },
        )
        lateinit var room: MlsRoom
        fun ui() = RoomUi(name, runCatching { room.syncState().joined }.getOrDefault(false), halted ?: store.haltReason(), log.all())
    }

    /** 설정 화면이 저장한 뒤 또는 앱 시작 때. 같은 scope 에서 한 번만. */
    fun start(scope: CoroutineScope) {
        if (loop != null || !settings.isConfigured) return
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
        val ls = FileLobbyStore(File(dir, "lobby"), seal = sealer::seal, open = sealer::open)
        lobbyStore = ls
        val l = ls.load()?.let { MlsLobby.`import`(identity, it, base, transport, ls) } ?: MlsLobby(identity, base, transport, ls)
        lobby = l
        for (f in dir.listFiles { _, n -> n.endsWith(".state") }.orEmpty()) {
            val name = f.name.removeSuffix(".state")
            val h = Handle(name)
            val (state, sync) = h.store.load() ?: continue
            h.room = MlsRoom.`import`(identity, name, state, sync, base, transport, h.store)
            rooms[name] = h
        }
        applyAccessToken()
        val fp = sha256Hex(l.publicKey())
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
        try {
            val s = l.status()
            _ui.update { it.copy(phase = Phase.Ready, lobbyLive = s.live.toInt(), lobbyMax = s.max.toInt(), connecting = false) }
        } catch (e: RoomException) {
            _ui.update { it.copy(phase = classify(e) ?: it.phase, connecting = e is RoomException.Relay && e.transient) }
        }
    }

    private fun classify(e: RoomException): Phase? = when {
        e is RoomException.Relay && e.transient -> null
        e is RoomException.Relay && "device_subject_mismatch" in e.reason -> Phase.WaitingEnrollment(enrollmentJson())
        e is RoomException.Relay && e.reason.contains("relay error 401") -> Phase.NeedsLogin
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
                    else -> { classify(e)?.let { p -> _ui.update { it.copy(phase = p) } }; notice("${h.name}: ${e.message}") }
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
                is SendResult.Sent -> h.log.append(MessageUi(r.seq, h.room.identity(), text, mine = true))
                is SendResult.Queued -> notice("연결되면 보냅니다")
                is SendResult.AlreadyDelivered -> {}
            }
            _ui.update { it.copy(rooms = rooms.values.map { r2 -> r2.ui() }) }
        } catch (e: RoomException) {
            notice(if (e is RoomException.Relay && e.transient) "연결 중입니다…" else (e.message ?: "전송 안 됨"))
        }
    }

    /** 설정 저장 뒤(세션 값 포함) 다시 접촉. */
    fun reconfigure(scope: CoroutineScope) = scope.launch(Dispatchers.IO) {
        mutex.withLock { applyAccessToken(); _ui.update { it.copy(phase = Phase.Starting) }; probe() }
    }

    fun retryEnrollment(scope: CoroutineScope) = reconfigure(scope)

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
        const val POLL_MS = 4_000L
        const val LOBBY_TARGET = 8
        const val REPLENISH_EVERY = 15 // ≈ 1분
        fun sha256Hex(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
