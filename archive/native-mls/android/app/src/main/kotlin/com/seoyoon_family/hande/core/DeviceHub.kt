// 기기 허브(#338 B1): Rust 코어(`MlsLobby` · `MlsRoom`)를 묶는 Kotlin 쪽 단일 작성자. HOST-CONTRACT §1 의 호스트 몫만 한다 —
// 호출 주기(전면 4 s poll) · 영속 어댑터(`FileLobbyStore`/`FileRoomStore` + Keystore 봉인) · 전송(`OkHttpTransport`) · 메시지 기록 · 화면 상태.
// 신원: 로비 상태가 곧 시드 — 방은 전부 `MlsRoom.adopt(identity, room, lobby.seedState(), …)` 로 만든다(서명키 하나, §2b).
// 참여 흐름: `replenish(8)` 로 로비 키를 올려 두면 운영자(steward 봇)가 초대 → `welcomes()` 에 방이 뜨면 `adopt(seq - 1)` → `poll` 이 join.
// 기기 셀프서비스(#574 PR 4, 웹 `app.js` enrollTick/discoverCandidates/approveViaRelay/processSiblingInvites/setRoles 와 같은 순서):
//   403 등록 대기 중 `POST /v2/devices/candidates` 로 후보를 올리고(「다른 기기에서 승인해 주세요」), 등록 기기는 우편함을 보고 승인하고
//   (`MlsLobby.approve` — 지문 재계산·서명·POST), 승인한 형제 기기를 내가 있는 방마다 초대하며(`MlsRoom.invite`, 대기열 재시도),
//   「내 기기」 에서 registrar 를 부여·해제한다(`MlsLobby.setRoles`). 판정은 `SelfService`(순수), 와이어·서명은 코어.
package com.seoyoon_family.hande.core

import android.content.Context
import android.util.Log
import com.seoyoon_family.hande.host.FileLobbyStore
import com.seoyoon_family.hande.host.FileRoomStore
import com.seoyoon_family.hande.mls.MlsCandidate
import com.seoyoon_family.hande.mls.MlsCandidateList
import com.seoyoon_family.hande.mls.MlsCandidatePost
import com.seoyoon_family.hande.mls.MlsInvite
import com.seoyoon_family.hande.mls.MlsLobby
import com.seoyoon_family.hande.mls.MlsMe
import com.seoyoon_family.hande.mls.MlsPolicyCommit
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
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

sealed interface Phase {
    /** 릴레이 주소·이름이 없다. */
    data object Setup : Phase
    data object Starting : Phase
    /**
     * 릴레이가 403 `device_subject_mismatch` — 체인에 없는 기기. `json` 은 등록 JSON(비밀 없음, 운영자 흐름).
     * `mode`(#574): SIBLING = 후보를 올렸고 같은 사람의 다른 기기가 승인한다(`expiresAt` ms 까지 유효, 그 5분 전에 다시 올린다) ·
     * ID_TAKEN = 이 ID 는 다시 쓸 수 없다 · OPERATOR = 첫 기기이거나 셀프서비스 없는 릴레이 — 운영자 CLI.
     */
    data class WaitingEnrollment(val json: String, val mode: SelfService.EnrollMode = SelfService.EnrollMode.OPERATOR, val expiresAt: Long? = null) : Phase
    /** 401 — 세션 값이 없거나 만료. */
    data object NeedsLogin : Phase
    data object Ready : Phase
    data class Fatal(val message: String) : Phase
}

/** `unread`(#571 후속): 마지막 글이 남의 글이고 본 위치 `max(Settings.readSeq, MlsRoom.readSeq())` 보다 뒤 — `Unread.isUnread`. */
data class RoomUi(val room: String, val joined: Boolean, val halted: String?, val messages: List<MessageUi>, val unread: Boolean)

/** 우편함의 새 기기 승인 요청 카드(#574). `expiresAt` ms. `message` 는 마지막 실패 사유. */
data class CandidateUi(val deviceId: String, val actor: String, val fingerprint: String, val expiresAt: Long?, val busy: Boolean, val message: String?)

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
    /** `/v2/me` 의 검증된 subject(#574) — 등록 JSON 의 보조 출처(정본은 세션 JWT 의 `sub`). */
    val subject: String? = null,
    /** 승인할 후보(등록 기기이거나 actor 에 registrar 가 없을 때만 채워진다). */
    val candidates: List<CandidateUi> = emptyList(),
    /** 「내 기기」(#574 E5): 체인의 내 기기 전부 + 역할 변경 가능 여부. 옛 릴레이(`/v2/me` 없음·기기 없음)는 null. */
    val devices: SelfService.RolesView? = null,
    /** 서버 표시(#584): `Settings.serverName`, 없으면 릴레이 호스트. 설정 전에는 null. */
    val server: String? = null,
)

class DeviceHub(context: Context, val settings: Settings, private val sealer: KeystoreSealer) {
    private val dir = File(context.filesDir, "mls").apply { mkdirs() }
    private val transport = OkHttpTransport()
    private val mutex = Mutex()
    private val _ui = MutableStateFlow(HubUi(phase = if (settings.isConfigured) Phase.Starting else Phase.Setup, server = serverLabel()))
    val ui: StateFlow<HubUi> = _ui
    /** 앱 versionName(`min_app.android` 와 견준다, #584). 못 읽으면 "0" — 서버가 최소 버전을 적어 두면 「앱이 오래됨」으로 막힌다. */
    private val appVersion: String = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "0"

    /** 정식 메시지 저장소(B2) — 프로세스에 하나. 내 글 판정은 읽을 때 actor 로(같은 사람의 다른 기기 글도 내 글). */
    private val db = MessageDb(context) { settings.deviceId }
    private var lobby: MlsLobby? = null
    private var lobbyStore: FileLobbyStore? = null
    private val rooms = LinkedHashMap<String, Handle>()
    private var loop: Job? = null
    private var ticks = 0

    // ---- 기기 셀프서비스 상태(#574) — 전부 메모리(대기열만 Settings) ----
    /** 마지막 `/v2/me`. 옛 릴레이(봉투 없는 404)면 다시 묻지 않는다(`meUnsupported`). */
    private var me: MlsMe? = null
    private var meUnsupported = false
    /** 셀프서비스 라우트가 없는 릴레이(봉투 없는 404) — 후보 게시·우편함을 다시 묻지 않는다. */
    private var selfServiceUnsupported = false
    /** 다음 후보 게시 시각(ms). 0 = 바로. `Long.MAX_VALUE` = 더는 안 올림(ID 사용 불가). */
    private var nextPostAt = 0L
    /** 우편함의 후보(내 actor, 모양 검사 통과)와 그 목록의 정책 revision(= 서명할 base_revision). */
    private var candidates: List<MlsCandidate> = emptyList()
    private var candidateRevision: ULong? = null
    private val dismissed = HashSet<String>()
    private val busy = HashSet<String>()
    private val candidateMessages = HashMap<String, String>()

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
        fun joined(): Boolean = runCatching { room.syncState().joined }.getOrDefault(false)
        fun ui(): RoomUi {
            val messages = db.messages(name)
            // 릴레이가 아는 같은 사람(actor)의 읽음 위치(#571 B) — 재시작 뒤 첫 poll 전에는 0 이므로 로컬 값과 max 로 합친다(웹 mergeRelayRead).
            val relayRead = runCatching { room.readSeq() }.getOrDefault(0L)
            val unread = Unread.isUnread(messages, maxOf(settings.readSeq(name), relayRead))
            return RoomUi(name, joined(), halted ?: store.haltReason(), messages, unread)
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
        _ui.update { it.copy(deviceId = identity, fingerprint = fp, keyCustody = sealer.describe(), rooms = rooms.values.map { r -> r.ui() }, server = serverLabel()) }
        probe()
    }

    /** 화면에 보일 서버: `.well-known` 의 이름, 없으면 릴레이 호스트(주소 직접 입력). 설정 전이면 null. */
    private fun serverLabel(): String? = settings.serverName ?: settings.relayUrl?.substringAfter("://")?.substringBefore('/')

    /**
     * 서버 탐색(#584 PR 3, 설정 화면의 「서버 찾기」·「확인」): 순수 로직은 `ServerDiscovery`, 전송은 `OkHttpTransport.get`(토큰 없음).
     * 저장은 화면이 한다(`Settings.relayUrl`·`serverName`) — 허브는 그 뒤 `start` 에서 읽는다.
     */
    suspend fun discover(input: String): ServerDiscovery.Result =
        withContext(Dispatchers.IO) { ServerDiscovery.discover(input, appVersion) { url -> transport.get(url) } }

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
            val wasWaiting = _ui.value.phase is Phase.WaitingEnrollment
            _ui.update { it.copy(phase = Phase.Ready, lobbyLive = s.live.toInt(), lobbyMax = s.max.toInt(), connecting = false, notice = if (wasWaiting) Strings.enrolledNow else null) }
            if (wasWaiting) nextPostAt = 0L
        } catch (e: RoomException) {
            Log.w(TAG, "probe: $e")
            val transient = e is RoomException.Relay && e.transient
            _ui.update { it.copy(phase = classify(e) ?: it.phase, connecting = transient, notice = if (transient || classify(e) != null) it.notice else e.message) }
        }
    }

    /**
     * 릴레이 응답 → 화면 단계. 봉투(`relay error <status>: <code>`)는 코드로, 봉투 없는 상태(`relay status <n>`)는 CF Access 엣지다:
     * 302(로그인 리다이렉트)·401·403(허용되지 않은 신원) → 세션 값 입력. 403 `device_subject_mismatch` 는 릴레이 본체(등록 대기).
     * 등록 대기 단계가 이미 셀프서비스 모드(후보 게시됨 등)면 그 모드를 지킨다 — `probe` 가 매번 운영자 화면으로 되돌리지 않게.
     */
    private fun classify(e: RoomException): Phase? = when {
        e is RoomException.Relay && e.transient -> null
        e is RoomException.Relay && "device_subject_mismatch" in e.reason ->
            (_ui.value.phase as? Phase.WaitingEnrollment)?.copy(json = enrollmentJson()) ?: Phase.WaitingEnrollment(enrollmentJson())
        e is RoomException.Relay && EDGE_AUTH.containsMatchIn(e.reason) -> Phase.NeedsLogin
        else -> null
    }

    private suspend fun tick() = mutex.withLock {
        val l = lobby ?: return@withLock
        ticks += 1
        val phase = _ui.value.phase
        if (phase !is Phase.Ready) {
            if (ticks % 3 == 0) probe()
            // 등록 대기(#574): 아직 403 이면 `/v2/me`(subject·내 기록) 와 후보 게시.
            if (_ui.value.phase is Phase.WaitingEnrollment) enrollTick(l)
            return@withLock
        }
        if (me == null || ticks % ME_EVERY_TICKS == 1) refreshMe(l)
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
        // 로비 Welcome → 모르는 방이면 로비 상태로 받아들인다(HOST-CONTRACT §2b). 운영자(steward)의 초대도, 같은 사람의 다른 기기가
        // 나를 방마다 초대한 것(#574 `from` = 활성 형제 기기)도 묻지 않고 받는다 — 이 앱에는 초대 카드가 없다.
        try {
            for (w in l.welcomes()) {
                if (rooms.containsKey(w.room)) continue
                val sibling = SelfService.isSibling(w.from, me, settings.actor, l.identity())
                Log.i(TAG, "welcome ${w.room} seq ${w.seq} from=${w.from.ifEmpty { "?" }} sibling=$sibling → adopt")
                val h = Handle(w.room)
                h.room = MlsRoom.adopt(l.identity(), w.room, l.seedState(), w.seq - 1, settings.relayUrl!!, transport, h.store)
                h.room.setAccessToken(settings.accessToken)
                rooms[w.room] = h
                h.room.poll()
                if (sibling) notice(Strings.siblingWelcome(w.from, w.room))
                replenish(l)
            }
        } catch (e: RoomException) {
            if (e is RoomException.Relay && e.transient) connecting = true else classify(e)?.let { p -> _ui.update { it.copy(phase = p) } }
        }
        if (ticks % REPLENISH_EVERY == 1) runCatching { replenish(l) }
        discoverCandidates(l)
        processSiblingInvites()
        _ui.update { it.copy(rooms = rooms.values.map { r -> r.ui() }, connecting = connecting) }
    }

    private fun replenish(l: MlsLobby) {
        val r = l.replenish(LOBBY_TARGET.toUInt())
        _ui.update { it.copy(lobbyLive = r.live.toInt(), lobbyMax = r.max.toInt()) }
    }

    // ---- 기기 셀프서비스(#574) ----

    /** `GET /v2/me` → subject · 정책 revision · 내 기기. 옛 릴레이(봉투 없는 404)는 한 번만 묻는다. 401 등은 `classify` 로 화면 단계에. */
    private fun refreshMe(l: MlsLobby) {
        if (meUnsupported) return
        try {
            val info = l.me()
            me = info
            _ui.update { it.copy(subject = info.subject, devices = if (info.policyRevision == null) null else SelfService.rolesActions(info, l.identity())) }
        } catch (e: RoomException) {
            when {
                e is RoomException.Relay && e.transient -> {}
                e is RoomException.Relay && "relay status 404" in e.reason -> { meUnsupported = true; Log.i(TAG, "me: relay has no /v2/me — self-service off") }
                else -> { Log.w(TAG, "me: $e"); classify(e)?.let { p -> _ui.update { it.copy(phase = p) } } }
            }
        }
    }

    /**
     * 등록 대기 틱(웹 `enrollTick`): `probe` 가 아직 403 이면 — 3틱마다 `/v2/me`(등록 JSON 의 subject 보조 출처), 그리고 후보 게시.
     * 첫 틱에 바로, 그 뒤 만료 5분 전에 다시(`SelfService.nextPostAt`). 404(옛 릴레이·접근 인증 꺼짐) → 운영자 흐름, 다시 묻지 않음.
     * 409 device_exists → ID 사용 불가(더는 안 올림). 403 first_device_out_of_band → 운영자 흐름, 5분마다 다시(그새 형제 기기가 생길 수 있다).
     * 체인에 내 기록이 활성으로 올라오면 다음 `probe`(3틱) 가 Ready 로 넘긴다.
     */
    private fun enrollTick(l: MlsLobby) {
        val now = System.currentTimeMillis()
        if (ticks % 3 == 0 || me == null) refreshMe(l)
        val current = _ui.value.phase as? Phase.WaitingEnrollment ?: return
        if (current.mode == SelfService.EnrollMode.ID_TAKEN || selfServiceUnsupported || now < nextPostAt) return
        val r = try {
            l.postCandidate()
        } catch (e: RoomException) {
            if (e is RoomException.Relay && e.transient) _ui.update { it.copy(connecting = true) } else { Log.w(TAG, "candidate: $e"); classify(e)?.let { p -> _ui.update { it.copy(phase = p) } } }
            return
        }
        when (r) {
            is MlsCandidatePost.Posted -> {
                val expiresAt = r.expiresAt * 1000L
                nextPostAt = SelfService.nextPostAt(expiresAt, now)
                Log.i(TAG, "candidate posted: policy revision ${r.policyRevision}, expires ${r.expiresAt}")
                _ui.update { it.copy(phase = Phase.WaitingEnrollment(enrollmentJson(), SelfService.EnrollMode.SIBLING, expiresAt), connecting = false) }
            }
            is MlsCandidatePost.Refused -> {
                val f = r.refusal
                val mode = SelfService.enrollModeFrom(f.status.toInt(), f.code)
                Log.i(TAG, "candidate refused: ${f.status} ${f.code} ${f.detail} → $mode")
                when {
                    f.status.toInt() == 404 && f.code.isEmpty() -> selfServiceUnsupported = true
                    mode == SelfService.EnrollMode.ID_TAKEN -> nextPostAt = Long.MAX_VALUE
                    else -> nextPostAt = now + SelfService.CANDIDATE_REPOST_MARGIN_MS
                }
                _ui.update { it.copy(phase = Phase.WaitingEnrollment(enrollmentJson(), mode, null), connecting = false) }
            }
        }
    }

    /** 우편함(틱마다, 이 기기가 승인할 수 있을 때만): 내 actor 의 후보만, 이번 실행에서 무시한 것은 뺀다. */
    private fun discoverCandidates(l: MlsLobby) {
        val identity = l.identity()
        if (selfServiceUnsupported || !SelfService.canApprove(me, identity)) { candidates = emptyList(); publishCandidates(); return }
        val r = try { l.listCandidates() } catch (e: RoomException) { Log.w(TAG, "candidates: $e"); return }
        when (r) {
            is MlsCandidateList.Listed -> {
                candidateRevision = r.policyRevision
                val rows = SelfService.candidatesFor(r.candidates, settings.actor ?: "").filter { it.deviceId !in dismissed }
                for (c in rows) if (candidates.none { it.deviceId == c.deviceId }) notice(Strings.candidateNew(c.deviceId))
                candidates = rows
            }
            is MlsCandidateList.Refused -> {
                if (r.refusal.status.toInt() == 404 && r.refusal.code.isEmpty()) selfServiceUnsupported = true
                candidates = emptyList()
            }
        }
        publishCandidates()
    }

    private fun publishCandidates() = _ui.update { ui ->
        ui.copy(candidates = candidates.map { c ->
            CandidateUi(c.deviceId, c.actor, c.fingerprint, c.expiresAt.takeIf { t -> t > 0L }?.let { t -> t * 1000L }, c.deviceId in busy, candidateMessages[c.deviceId])
        })
    }

    /**
     * 「지문 비교 후 승인」(웹 `approveViaRelay`): 사람이 새 기기 화면의 지문과 카드의 지문을 견준 뒤 누른다. 코어 `MlsLobby.approve` 가
     * 후보 공개키로 지문을 다시 계산해 다르면 거부하고, `sign_approval` → `POST /v2/devices/approvals`. 409 stale_revision 이면 릴레이가 준
     * revision 으로 한 번 다시 서명. 403 은 `detail` 을 카드에. 201 이면 `/v2/me` 를 새로 읽고 내가 있는 방마다 초대를 대기열에 넣는다.
     */
    fun approve(scope: CoroutineScope, deviceId: String) = scope.launch(Dispatchers.IO) {
        mutex.withLock {
            val l = lobby ?: return@withLock
            val c = candidates.firstOrNull { it.deviceId == deviceId } ?: return@withLock
            if (!busy.add(deviceId)) return@withLock
            candidateMessages.remove(deviceId)
            publishCandidates()
            try {
                var base: ULong? = candidateRevision ?: me?.policyRevision
                for (attempt in 0 until 2) {
                    if (base == null || base < 1uL) { candidateMessages[deviceId] = Strings.candidateNoRevision; return@withLock }
                    when (val r = l.approve(c, base)) {
                        is MlsPolicyCommit.Committed -> {
                            Log.i(TAG, "approved $deviceId → policy revision ${r.revision} (approved_by ${r.approvedBy})")
                            candidates = candidates.filter { it.deviceId != deviceId }
                            notice(Strings.candidateApproved(deviceId))
                            refreshMe(l)
                            queueSiblingInvites(deviceId)
                            return@withLock
                        }
                        is MlsPolicyCommit.Refused -> {
                            val f = r.refusal
                            if (f.status.toInt() == 409 && f.code == "stale_revision" && attempt == 0) {
                                Log.i(TAG, "approve $deviceId: stale revision $base → ${f.revision}")
                                base = f.revision?.takeIf { it > 0L }?.toULong() ?: run { refreshMe(l); me?.policyRevision }
                                continue
                            }
                            candidateMessages[deviceId] = Strings.candidateRejected(f.detail.ifEmpty { "${f.status} ${f.code}" })
                            return@withLock
                        }
                    }
                }
            } catch (e: RoomException) {
                Log.w(TAG, "approve $deviceId: $e")
                candidateMessages[deviceId] = if (e is RoomException.Mls && "fingerprint mismatch" in e.reason) Strings.candidateMismatch else Strings.candidateFailed(e.message ?: "?")
            } finally {
                busy.remove(deviceId)
                publishCandidates()
            }
        }
    }

    /** 카드의 「무시」: 이번 실행 동안 보이지 않는다(우편함의 행은 10분 뒤 사라진다). */
    fun dismissCandidate(scope: CoroutineScope, deviceId: String) = scope.launch(Dispatchers.IO) {
        mutex.withLock { dismissed += deviceId; candidates = candidates.filter { it.deviceId != deviceId }; publishCandidates() }
    }

    /** 승인 직후: 내가 참여한(정지 아닌) 방마다 새 형제 기기를 초대하도록 대기열에 적는다 — 틱마다 `processSiblingInvites` 가 시도한다. */
    private fun queueSiblingInvites(target: String) {
        val list = SelfService.siblingInviteRooms(rooms.values.map { SelfService.RoomView(it.name, it.joined(), (it.halted ?: it.store.haltReason()) != null) })
        if (list.isEmpty()) return
        val queue = SelfService.enqueueSiblingInvites(SelfService.decodeSiblingQueue(settings.siblingQueue), target, list, System.currentTimeMillis())
        settings.siblingQueue = SelfService.encodeSiblingQueue(queue)
        Log.i(TAG, "sibling $target queued for ${list.joinToString(",")}")
    }

    /**
     * 형제 기기 초대(#574, 웹 `processSiblingInvites`): 막 승인된 기기는 다음 틱에야 로비 키를 올리므로 첫 초대는 보통 `NoKeyPackage` —
     * 방을 대기열에 두고 다음 틱에 다시. `Pending`(내 commit 대기)·`Raced`(방이 먼저 바뀜)도 다시. 그 밖의 오류는 포기하고 알린다.
     * 30분이 지나면 포기(알림). `Invited`/`Posted` = 끝(Welcome 은 코어가 echo 뒤 올린다).
     */
    private fun processSiblingInvites() {
        val queue = SelfService.decodeSiblingQueue(settings.siblingQueue)
        if (queue.isEmpty()) return
        val (live, expired) = SelfService.splitSiblingQueue(queue, System.currentTimeMillis())
        for (e in expired) { Log.w(TAG, "sibling ${e.target}: gave up after 30 min (${e.rooms})"); notice(Strings.siblingGaveUp(e.target)) }
        val next = ArrayList<SelfService.SiblingInvite>()
        for (e in live) {
            val remaining = ArrayList<String>()
            for (room in e.rooms) {
                val h = rooms[room] ?: continue
                if ((h.halted ?: h.store.haltReason()) != null || !h.joined()) continue
                val r = try {
                    h.room.invite(e.target)
                } catch (ex: RoomException) {
                    if (ex is RoomException.Relay && ex.transient) remaining += room
                    else { Log.w(TAG, "sibling ${e.target} in $room: $ex"); notice(Strings.siblingFailed(e.target, room, ex.message ?: "?")) }
                    continue
                }
                when (r) {
                    is MlsInvite.Invited, is MlsInvite.Posted -> { Log.i(TAG, "sibling ${e.target} invited into $room: $r"); notice(Strings.siblingInvited(e.target, room)) }
                    is MlsInvite.NoKeyPackage, is MlsInvite.Pending, is MlsInvite.Raced -> remaining += room
                }
            }
            if (remaining.isNotEmpty()) next += e.copy(rooms = remaining)
        }
        settings.siblingQueue = SelfService.encodeSiblingQueue(next)
    }

    /**
     * 「내 기기」의 registrar 부여/해제(E5, 웹 `setRoles`): 대상의 완전한 역할 목록(`SelfService.nextRoles`)에 `sign_roles` →
     * `POST /v2/devices/roles`. 409 stale_revision 이면 `/v2/me` 를 다시 읽고(대상의 역할도 움직였을 수 있다) 한 번 다시 서명.
     * 가능 여부는 화면이 `SelfService.rolesActions` 로 미리 가린다; 서버가 거절하면(403) `detail` 을 알린다.
     */
    fun setRoles(scope: CoroutineScope, targetId: String, grant: Boolean) = scope.launch(Dispatchers.IO) {
        mutex.withLock {
            val l = lobby ?: return@withLock
            var base: ULong? = me?.policyRevision
            for (attempt in 0 until 2) {
                val target = SelfService.recordOf(me, targetId) ?: run { notice(Strings.devicesUnknown(targetId)); return@withLock }
                if (base == null || base < 1uL) { notice(Strings.candidateNoRevision); return@withLock }
                val r = try {
                    l.setRoles(target.deviceId, target.actor, SelfService.nextRoles(target.roles, grant), base)
                } catch (e: RoomException) { Log.w(TAG, "roles $targetId: $e"); notice(Strings.rolesFailed(e.message ?: "?")); return@withLock }
                when (r) {
                    is MlsPolicyCommit.Committed -> {
                        Log.i(TAG, "roles $targetId=${r.roles} → policy revision ${r.revision}")
                        notice(Strings.rolesDone(targetId, grant))
                        refreshMe(l)
                        return@withLock
                    }
                    is MlsPolicyCommit.Refused -> {
                        val f = r.refusal
                        if (f.status.toInt() == 409 && f.code == "stale_revision" && attempt == 0) {
                            refreshMe(l)
                            base = f.revision?.takeIf { it > 0L }?.toULong() ?: me?.policyRevision
                            continue
                        }
                        notice(Strings.rolesRejected(f.detail.ifEmpty { "${f.status} ${f.code}" }))
                        return@withLock
                    }
                }
            }
        }
    }

    /** 「내 기기」를 열 때: `/v2/me` 를 바로 새로 읽는다(다음 4틱을 기다리지 않게). */
    fun refreshDevices(scope: CoroutineScope) = scope.launch(Dispatchers.IO) { mutex.withLock { lobby?.let { refreshMe(it) } } }

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

    /** 설정 저장 뒤(세션 값 포함) 다시 접촉. 새 세션이면 `/v2/me` 와 후보 게시도 처음부터. */
    fun reconfigure(scope: CoroutineScope) = scope.launch(Dispatchers.IO) {
        mutex.withLock { applyAccessToken(); me = null; meUnsupported = false; selfServiceUnsupported = false; nextPostAt = 0L; _ui.update { it.copy(phase = Phase.Starting) }; probe() }
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

    /**
     * 이 기기 지우기(#584 Play 「계정 삭제」의 앱 내 경로 · iOS §9-5 상당, 설정 화면의 확인 대화상자 뒤): poll 을 멈추고 로비·방 객체를 닫은 뒤
     * `files/mls`(봉인된 MLS 상태·로비 슬롯·정지 마커) · `messages.db` · SharedPreferences(세션 값·기기 ID 접미 포함) · Keystore 봉인 키를 지운다.
     * 다음 처음 설정은 **새 기기**(새 접미) — 옛 기기 ID 는 릴레이 체인에 남아 다시 쓸 수 없고, 그 폐기(E3)·방 데이터 삭제는 앱 권한 밖이라
     * 웹 안내(`BuildConfig.DELETE_ACCOUNT_URL`, docs/hande/delete-account.md)로 요청한다. 같은 Activity scope 에서 `start` 를 다시 부를 수 있도록 `loop` 를 비운다.
     */
    fun wipeDevice(scope: CoroutineScope) = scope.launch(Dispatchers.IO) {
        loop?.cancel()
        loop = null
        mutex.withLock {
            Log.i(TAG, "wipe: closing ${rooms.size} rooms + lobby, deleting local state")
            rooms.values.forEach { h -> runCatching { h.room.close() }.onFailure { e -> Log.w(TAG, "wipe: close ${h.name}: $e") } }
            rooms.clear()
            runCatching { lobby?.close() }.onFailure { e -> Log.w(TAG, "wipe: close lobby: $e") }
            lobby = null
            lobbyStore = null
            me = null; meUnsupported = false; selfServiceUnsupported = false; nextPostAt = 0L
            candidates = emptyList(); candidateRevision = null
            dismissed.clear(); busy.clear(); candidateMessages.clear()
            ticks = 0
            runCatching { db.wipe() }.onFailure { e -> Log.w(TAG, "wipe: messages.db: $e") }
            if (!dir.deleteRecursively()) Log.w(TAG, "wipe: some files under ${dir.name} could not be deleted")
            dir.mkdirs()
            settings.wipe()
            runCatching { sealer.forget() }.onFailure { e -> Log.w(TAG, "wipe: keystore: $e") }
            _ui.value = HubUi(phase = Phase.Setup, notice = Strings.wipeDone)
            Log.i(TAG, "wipe: done → setup")
        }
    }

    /**
     * 등록 JSON — 운영자 CLI(`-enroll-first`/`-add-device`) 입력과 키가 같다(iOS `EnrollmentRequest`). 비밀 없음.
     * `subject` = 세션 JWT 의 `sub`(`AppLogin.subjectOf`, iOS PR #347 과 같은 출처); 없으면(서비스 토큰) `/v2/me` 가 답한 subject;
     * 그것도 없으면 빈값(운영자가 채운다). 릴레이는 subject ≠ 실제 `sub` 면 403 으로 거부하므로 여기 값이 권한을 만들지는 않는다.
     */
    fun enrollmentJson(): String {
        val l = lobby ?: return ""
        val id = l.identity()
        val pub = l.publicKey()
        return JSONObject()
            .put("actor", id.substringBefore('-'))
            .put("device_id", id)
            .put("fingerprint", sha256Hex(pub))
            .put("signing_key", pub.joinToString("") { "%02x".format(it) })
            .put("subject", AppLogin.subjectOf(settings.accessToken) ?: me?.subject ?: "")
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
        /** `GET /v2/me` 주기(#574, 웹 `ME_EVERY_TICKS`) — 체인이 바뀐 직후(승인·역할)에는 바로 다시 읽는다. */
        const val ME_EVERY_TICKS = 4
        fun sha256Hex(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
