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
import android.os.SystemClock
import android.util.Log
import com.seoyoon_family.hande.host.FileLobbyStore
import com.seoyoon_family.hande.host.FileRoomStore
import com.seoyoon_family.hande.mls.HttpHeader
import com.seoyoon_family.hande.mls.MlsCandidate
import com.seoyoon_family.hande.mls.MlsCandidateList
import com.seoyoon_family.hande.mls.MlsCandidatePost
import com.seoyoon_family.hande.mls.MlsInvite
import com.seoyoon_family.hande.mls.MlsLobby
import com.seoyoon_family.hande.mls.MlsMe
import com.seoyoon_family.hande.mls.MlsPolicyCommit
import com.seoyoon_family.hande.mls.MlsRoom
import com.seoyoon_family.hande.mls.MlsWatchRoom
import com.seoyoon_family.hande.mls.RoomEvent
import com.seoyoon_family.hande.mls.RoomException
import com.seoyoon_family.hande.mls.SendResult
import com.seoyoon_family.hande.mls.fileV2Check
import com.seoyoon_family.hande.mls.fileV2Sniff
import com.seoyoon_family.hande.ui.AttachmentIo
import com.seoyoon_family.hande.ui.AttachmentThumbs
import com.seoyoon_family.hande.ui.Strings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
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
data class RoomUi(
    val room: String, val joined: Boolean, val halted: String?, val messages: List<MessageUi>, val unread: Boolean,
    /** status-v1(#560): 에이전트 작업 상태 임시 말풍선(보낸이별 하나) — 대화방 맨 아래. 저장하지 않는다. */
    val statuses: List<StatusUi> = emptyList(),
    /** 대화 목록 미리보기 자리에 보일 최신 「⏳ Working …」 줄(오너 2026-10-30). 없으면 null. */
    val working: String? = null,
)

/** 우편함의 새 기기 승인 요청 카드(#574). `expiresAt`·`createdAt` ms(릴레이가 안 주면 null — 디자인 2차-A 카드의 「요청 HH:mm · HH:mm에 만료」). `message` 는 마지막 실패 사유. */
data class CandidateUi(
    val deviceId: String, val actor: String, val fingerprint: String, val expiresAt: Long?, val busy: Boolean, val message: String?,
    val createdAt: Long? = null,
)

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
    /** 방 순서를 릴레이와 맞추는가(#715) — 옛 릴레이(404)면 false(이 기기에만 저장). 순서 편집 안내 문구가 고른다. */
    val roomOrderSynced: Boolean = true,
    /** 설정 「빠진 방 다시 찾기」(#616, 기본 켜짐 — `Settings.siblingRescanOff`). */
    val siblingRescan: Boolean = true,
)

class DeviceHub(context: Context, val settings: Settings, private val sealer: KeystoreSealer) {
    private val dir = File(context.filesDir, "mls").apply { mkdirs() }
    private val transport = OkHttpTransport()
    /**
     * 링크 미리보기(#683 2단계 · v2 #690) — 릴레이 주소·세션 값은 요청할 때마다 설정에서 읽는다(로그인·서버 변경 즉시 반영).
     * 사이트 목록(`linkPreviews.sites`)은 준비 단계(로그인 뒤)에 세션당 한 번 받고(`loadSites`), 다시 설정·로그인·지우기 때 비운다.
     */
    val linkPreviews = LinkPreviews(relayUrl = { settings.relayUrl }, accessToken = { settings.accessToken }, http = transport)
    private val mutex = Mutex()
    private val _ui = MutableStateFlow(HubUi(phase = if (settings.isConfigured) Phase.Starting else Phase.Setup, server = serverLabel()))
    val ui: StateFlow<HubUi> = _ui
    /**
     * 대화 목록 순서(#715 room-order v1 · #549): 로컬 순서(`Settings.roomOrder`)와 릴레이(`GET/PUT /v2/me/room-order`)를 맞춘다 — 규칙은 `RoomOrderSync`.
     * 네트워크는 허브 mutex 밖 `orderScope` 에서 `orderMutex` 로 한 번에 하나씩(방 poll·전송을 막지 않고, 화면도 막지 않는다).
     * 인증은 코어 요청과 같은 `Cf-Access-Jwt-Assertion`(세션 값), actor 판정은 릴레이가 `device` 로 한다.
     */
    private val orderScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val orderMutex = Mutex()
    private val roomOrder = RoomOrderSync(
        store = settings, relayUrl = { settings.relayUrl }, device = { settings.deviceId },
        http = ::orderHttp, now = { SystemClock.elapsedRealtime() }, log = { Log.i(TAG, it) },
    ).also { sync ->
        // 채택·이동 뒤 지금 목록을 새 순서로 다시 늘어놓는다(저장 순서에 없는 방의 기본 순서는 다음 틱의 `roomList` 가 바로잡는다).
        sync.onChange = { order -> _ui.update { ui -> ui.copy(rooms = RoomOrder.apply(ui.rooms, order) { r -> r.room }, roomOrderSynced = sync.synced) } }
    }
    /** 앱 versionName(`min_app.android` 와 견준다, #584). 못 읽으면 "0" — 서버가 최소 버전을 적어 두면 「앱이 오래됨」으로 막힌다. */
    private val appVersion: String = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "0"

    init {
        // #366 C: 지난 실행이 남긴 임시 공유 파일(복호화한 첨부)을 지운다 — 이력에는 원래 저장하지 않는다(FILE-V2 §4-2).
        AttachmentIo.clearShared(context)
    }

    /** 정식 메시지 저장소(B2) — 프로세스에 하나. 내 글 판정은 읽을 때 actor 로(같은 사람의 다른 기기 글도 내 글). */
    private val db = MessageDb(context) { settings.deviceId }
    private var lobby: MlsLobby? = null
    private var lobbyStore: FileLobbyStore? = null
    private val rooms = LinkedHashMap<String, Handle>()
    /**
     * poll 루프는 허브(프로세스) 수명 scope 에서 돈다(#766 A) — 화면(Activity) scope 에 묶으면 회전·다크모드 전환·Activity 회수 때
     * 취소된 채 남아 프로세스를 다시 시작할 때까지 새 글이 오지 않는다. 수명 규칙은 `HubLoop`.
     */
    private val loop = HubLoop(CoroutineScope(SupervisorJob() + Dispatchers.IO))
    /** #755: 다음 `watch` 의 방별 커서(틱 끝에 잠금 안에서 찍는다) · 릴레이가 `/v2/watch` 를 모르면 참. */
    @Volatile private var watchTargets: List<MlsWatchRoom> = emptyList()
    @Volatile private var watchUnsupported = false
    private var ticks = 0
    /** #766 E: 마지막 전 방 훑기 · 마지막 로비 쪽 일(초대·후보·재탐색) 시각(`elapsedRealtime`). null = 다음 틱에 바로. 허브 mutex 안에서만. */
    private var fullSweepAt: Long? = null
    private var auxAt: Long? = null

    // ---- 기기 셀프서비스 상태(#574) — 메모리(초대 대기열·「무시」한 후보는 Settings 에 영속) ----
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
    private val busy = HashSet<String>()
    private val candidateMessages = HashMap<String, String>()

    private inner class Handle(val name: String) {
        var halted: String? = null
        /** 이번 틱의 `poll` 이 성공했나(#616 재탐색은 참여한 방이 모두 최신일 때만). */
        var synced = false
        /** 그룹 명단 캐시(#616): 엔진 `members` 는 `MlsRoom.dispatch` 라 부를 때마다 상태를 다시 쓴다 — 명단은 epoch 가 바뀔 때만 움직이므로 epoch 로 맞춘다. */
        var rosterEpoch = Long.MIN_VALUE
        var roster: List<String>? = null
        /** status-v1(#560): 이 방의 보낸이별 최신 작업 상태(메모리만). onMessage·ui() 모두 DeviceHub mutex 안에서 불린다. */
        val statuses = AgentStatusBoard()
        val store = FileRoomStore(
            dir, name, seal = sealer::seal, open = sealer::open,
            onEvent = { e ->
                when (e) {
                    is RoomEvent.Joined -> notice("$name 대화방에 참여했습니다")
                    // #574 후속: 코어가 영속해 둔 대기 Welcome 을 버렸다(그 commit 이 merge 없이 사라짐) — 대상을 대기열에 되돌려 다음 틱에 다시 초대한다.
                    is RoomEvent.WelcomeDropped -> {
                        Log.w(TAG, "$name: pending welcome for ${e.targets} dropped (commit seq ${e.commitSeq}) → re-queued")
                        for (t in e.targets) requeueSiblingInvite(t, name)
                    }
                    else -> {}
                }
            },
            onMessage = { seq, sender, clientId, plaintext ->
                // file-v2 평문은 파일 키가 든 설명자 — 글로 저장·표시하지 않는다(#499, FileV2.classify).
                // status-v1(#560): 에이전트 작업 상태 한 줄은 저장하지 않고 임시 말풍선 보드에만 둔다.
                if (FileV2.isStatusClientId(clientId)) {
                    statuses.apply(sender, String(plaintext, Charsets.UTF_8), seq, System.currentTimeMillis())
                    return@FileRoomStore
                }
                val row = FileV2.classify(clientId, plaintext) ?: return@FileRoomStore
                if (row.kind == MessageSchema.KIND_UNDECRYPTABLE) Log.w(TAG, "$name seq $seq: file-v2 message rejected")
                db.insert(name, seq, sender, clientId, row.kind, row.body, row.attachment)
                // 같은 보낸이의 다음 일반 메시지(답·첨부)가 오면 그 보낸이의 작업 상태는 끝난다.
                statuses.clear(sender, seq)
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
            val h = halted ?: store.haltReason()
            val now = System.currentTimeMillis()
            val live = if (h == null) statuses.visible(now) else emptyList()
            return RoomUi(name, joined(), h, messages, unread, statuses = live, working = live.lastOrNull()?.text)
        }
    }

    /** 설정 화면이 저장한 뒤 또는 앱 시작 때. 프로세스에서 한 번만 — 화면이 다시 만들어져 또 불려도 도는 루프는 그대로다(#766 A). */
    fun start() {
        if (loop.started || !settings.isConfigured) return
        _ui.update { it.copy(phase = Phase.Starting) }
        loop.start body@{
            try {
                boot()
            } catch (e: Throwable) {
                _ui.update { it.copy(phase = Phase.Fatal(e.message ?: e.toString())) }
                return@body
            }
            var wake: WatchPlan.Wake? = null
            while (isActive) {
                tick(wake)
                wake = waitForChange()
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
        _ui.update { it.copy(deviceId = identity, fingerprint = fp, keyCustody = sealer.describe(), rooms = roomList(), server = serverLabel(), roomOrderSynced = roomOrder.synced, siblingRescan = !settings.siblingRescanOff) }
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
            linkPreviews.loadSites()
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

    /**
     * 한 틱. #766 E: [wake](직전 대기의 결과)로 poll 할 방을 고른다(`WatchPlan.plan`) — watch 가 알려 준 바뀐 방만, 전 방 훑기는 첫 틱 ·
     * watch 미지원·오류 · 60 s 안전망일 때만. 로비 쪽 일(초대·후보·재탐색)은 `WatchPlan.auxDue` 주기로, 방 목록은 그 앞에서 먼저 화면에 낸다.
     */
    private suspend fun tick(wake: WatchPlan.Wake?) = mutex.withLock {
        val l = lobby ?: return@withLock
        ticks += 1
        val phase = _ui.value.phase
        if (phase !is Phase.Ready) {
            // 준비 단계로 돌아오면 첫 틱처럼 전 방 훑기·로비 쪽 일을 바로 한다.
            fullSweepAt = null
            auxAt = null
            if (ticks % 3 == 0) probe()
            // 등록 대기(#574): 아직 403 이면 `/v2/me`(subject·내 기록) 와 후보 게시.
            if (_ui.value.phase is Phase.WaitingEnrollment) enrollTick(l)
            return@withLock
        }
        if (me == null || ticks % ME_EVERY_TICKS == 1) refreshMe(l)
        linkPreviews.loadSites() // 받았거나 받는 중·재시도 시각 전이면 아무것도 안 한다(일시 실패만 10분 뒤 다시)
        var connecting = false
        val now = SystemClock.elapsedRealtime()
        val sweep = WatchPlan.plan(
            rooms.values.map { h -> WatchPlan.Room(h.name, halted = (h.halted ?: h.store.haltReason()) != null, synced = h.synced) },
            wake, fullSweepAt, now,
        )
        val targets = when (sweep) {
            is WatchPlan.Sweep.Full -> { fullSweepAt = now; rooms.values.toList() }
            is WatchPlan.Sweep.Only -> sweep.rooms.mapNotNull { rooms[it] }
        }
        for (h in targets) {
            h.synced = false
            try {
                h.room.poll()
                h.synced = true
            } catch (e: RoomException) {
                when {
                    e is RoomException.Relay && e.transient -> connecting = true
                    e is RoomException.Relay && "room_closed" in e.reason -> h.halted = "room_closed"
                    else -> { Log.w(TAG, "poll ${h.name}: $e"); classify(e)?.let { p -> _ui.update { it.copy(phase = p) } }; notice("${h.name}: ${e.message}") }
                }
            }
        }
        val aux = WatchPlan.auxDue(auxAt, now)
        // 바뀐 방의 새 글은 로비 쪽 일을 기다리지 않고 먼저 화면에.
        if (aux && targets.isNotEmpty()) _ui.update { it.copy(rooms = roomList(), connecting = connecting) }
        if (aux) {
            auxAt = now
            if (lobbyAux(l)) connecting = true
        }
        if (ticks % REPLENISH_EVERY == 1) runCatching { replenish(l) }
        processSiblingInvites()
        _ui.update { it.copy(rooms = roomList(), connecting = connecting, roomOrderSynced = roomOrder.synced) }
        kickRoomOrder()
        // #755: 다음 대기에 쓸 방별 커서 — 잠금 안에서 찍고, 대기는 잠금 밖에서 한다(보내기·화면 조작이 막히지 않게).
        watchTargets = rooms.values.filter { it.halted == null }.mapNotNull { h ->
            runCatching { MlsWatchRoom(h.name, h.room.syncState().cursor) }.getOrNull()
        }.take(WATCH_MAX_ROOMS)
    }

    /**
     * 로비 쪽 일(#766 E — 틱마다가 아니라 `WatchPlan.AUX_EVERY_MS` 주기): 초대 Welcome 받기 · 승인 후보 · 빠진 방 재탐색.
     * Welcome 조회가 일시 오류(연결 중)였으면 참.
     */
    private fun lobbyAux(l: MlsLobby): Boolean {
        var connecting = false
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
                h.synced = true
                if (sibling) notice(Strings.siblingWelcome(w.from, w.room))
                replenish(l)
            }
        } catch (e: RoomException) {
            if (e is RoomException.Relay && e.transient) connecting = true else classify(e)?.let { p -> _ui.update { it.copy(phase = p) } }
        }
        discoverCandidates(l)
        rescanSiblings(l)
        return connecting
    }

    /**
     * 틱 사이 대기(#755 1단계). 릴레이가 `GET /v2/watch`(#424)를 알면 방 전체를 요청 하나로 기다렸다가 바뀌는 즉시 다음 틱으로
     * 간다 — 4초 폴링(방마다 GET)이 「바뀔 때 한 번」이 된다. **잠금을 잡지 않는다**(`MlsLobby.watch` 도 로비 잠금 밖).
     * 대기는 OkHttp read timeout(15 s)보다 짧게 [WATCH_WAIT_MS]. #424 이전 릴레이(`supported = false`)·오류·준비 전에는 지금처럼
     * [POLL_MS]. 미지원 판정은 [WATCH_REPROBE_TICKS] 틱마다 다시 확인한다(릴레이가 나중에 올라와도 앱 재시작 없이 붙게).
     * 틱 간격은 최소 [MIN_TICK_GAP_MS] — typing 처럼 잦은 변화가 틱을 몰아치지 않게.
     * #766 E: watch 결과(바뀐 방·거절된 방)를 돌려준다 — 다음 틱은 그 방만 poll 한다. watch 를 못 썼으면 [WatchPlan.Wake.Unknown](전 방 훑기).
     */
    private suspend fun waitForChange(): WatchPlan.Wake {
        val l = lobby
        val targets = watchTargets
        if (watchUnsupported && ticks % WATCH_REPROBE_TICKS == 0) watchUnsupported = false
        if (l == null || _ui.value.phase !is Phase.Ready || targets.isEmpty() || watchUnsupported) {
            delay(POLL_MS)
            return WatchPlan.Wake.Unknown
        }
        val started = SystemClock.elapsedRealtime()
        val wake = try {
            val r = l.watch(targets, WATCH_WAIT_MS.toUInt())
            if (!r.supported) {
                Log.i(TAG, "watch: relay predates #424 — fixed ${POLL_MS} ms polling")
                watchUnsupported = true
                delay(POLL_MS)
                return WatchPlan.Wake.Unknown
            }
            WatchPlan.Wake.Watched(targets.map { it.room }.toSet(), r.changed, r.refused.map { it.room })
        } catch (e: RoomException) {
            Log.w(TAG, "watch: $e — ${POLL_MS} ms polling this round")
            delay(POLL_MS)
            return WatchPlan.Wake.Unknown
        }
        val spent = SystemClock.elapsedRealtime() - started
        if (spent < MIN_TICK_GAP_MS) delay(MIN_TICK_GAP_MS - spent)
        return wake
    }

    /** 화면 목록: 저장된 순서를 먼저, 거기 없는 방은 기본 순서(참여 순서)로 뒤에(#715 규칙 3 · `RoomOrder.apply`). */
    private fun roomList(): List<RoomUi> = RoomOrder.apply(rooms.values.map { it.ui() }, roomOrder.order) { it.room }

    // ---- 대화 목록 순서(#715 room-order v1 · #549 편집) ----

    /** 준비 단계에서 때가 됐으면(시작·로그인·전면 복귀·일시 실패 뒤, 최소 60초 간격) GET 을 IO 에 띄운다. 네트워크 없이 바로 돌아온다. */
    private fun kickRoomOrder() {
        if (_ui.value.phase !is Phase.Ready || !roomOrder.isDue()) return
        orderScope.launch {
            orderMutex.withLock { roomOrder.sync() }
            _ui.update { it.copy(roomOrderSynced = roomOrder.synced) }
        }
    }

    /** 순서 동기화용 인증 요청(코어와 같은 헤더). 응답이 없으면 null — `RoomOrderSync` 가 다음 주기에 다시 한다. */
    private fun orderHttp(method: String, url: String, body: ByteArray?): RoomOrderSync.Reply? {
        val token = settings.accessToken?.trim()?.takeIf { it.isNotEmpty() }
        val headers = if (token == null) emptyList() else listOf(HttpHeader(ACCESS_HEADER, token))
        return try {
            transport.send(method, url, headers, body).let { RoomOrderSync.Reply(it.status.toInt(), it.body) }
        } catch (e: RoomException) {
            Log.w(TAG, "room-order $method: ${e.message}")
            null
        }
    }

    /** 앱이 전면으로 돌아왔다(`MainActivity.onResume`) — 규칙 1 의 계기. 60초 간격은 `RoomOrderSync` 가 지킨다. */
    fun onForeground() {
        roomOrder.request()
        kickRoomOrder()
    }

    /** 순서 편집 ▲(−1)/▼(+1): 화면 순서에서 한 칸. 끝이면 아무것도 안 한다. */
    fun moveRoom(room: String, delta: Int) = reorder { ids -> RoomOrder.step(ids, room, delta) }

    /** 순서 편집 「맨 위로 고정」. */
    fun moveRoomToTop(room: String) = reorder { ids -> RoomOrder.moveToTop(ids, room) }

    /**
     * 규칙 2: 로컬에 바로 반영(화면도 바로 — `onChange`)하고 PUT 은 IO 에서. 저장 순서 = 옮긴 화면 순서 + 지금 목록에 없는 저장 ID(다른 기기에만 있는 방).
     * 화면 스레드에서 불러도 된다(네트워크 없음).
     */
    private fun reorder(change: (List<String>) -> List<String>?) {
        val next = change(_ui.value.rooms.map { it.room }) ?: return
        roomOrder.move(RoomOrder.withHidden(next, roomOrder.order))
        orderScope.launch {
            orderMutex.withLock { roomOrder.push() }
            _ui.update { it.copy(roomOrderSynced = roomOrder.synced) }
        }
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

    /** 우편함(틱마다, 이 기기가 승인할 수 있을 때만): 내 actor 의 후보만, 「무시」한 것(`Settings.dismissedCandidates`, 후보 TTL 뒤 만료)은 뺀다. */
    private fun discoverCandidates(l: MlsLobby) {
        val identity = l.identity()
        if (selfServiceUnsupported || !SelfService.canApprove(me, identity)) { candidates = emptyList(); publishCandidates(); return }
        val r = try { l.listCandidates() } catch (e: RoomException) { Log.w(TAG, "candidates: $e"); return }
        when (r) {
            is MlsCandidateList.Listed -> {
                candidateRevision = r.policyRevision
                val nowSec = System.currentTimeMillis() / 1000L
                val stored = SelfService.decodeDismissals(settings.dismissedCandidates)
                val dismissals = SelfService.pruneDismissals(stored, nowSec)
                if (dismissals.size != stored.size) settings.dismissedCandidates = SelfService.encodeDismissals(dismissals)
                val rows = SelfService.candidatesFor(r.candidates, settings.actor ?: "").filter { !SelfService.isDismissed(dismissals, it.deviceId, nowSec) }
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
            CandidateUi(
                c.deviceId, c.actor, c.fingerprint, c.expiresAt.takeIf { t -> t > 0L }?.let { t -> t * 1000L }, c.deviceId in busy, candidateMessages[c.deviceId],
                createdAt = c.createdAt.takeIf { t -> t > 0L }?.let { t -> t * 1000L },
            )
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

    /**
     * 카드의 「무시」(#574 후속): 프로세스가 다시 떠도 숨긴다 — `Settings.dismissedCandidates` 에 (기기 ID, 그 후보의 `created_at`) 을 적고
     * 후보 TTL(10분) 뒤 만료한다(`SelfService.dismiss`; 재게시로 `created_at` 이 바뀌어도 ID 로 숨긴다). 영영 숨기지는 않는다.
     */
    fun dismissCandidate(scope: CoroutineScope, deviceId: String) = scope.launch(Dispatchers.IO) {
        mutex.withLock {
            val nowSec = System.currentTimeMillis() / 1000L
            val createdAt = candidates.firstOrNull { it.deviceId == deviceId }?.createdAt ?: 0L
            settings.dismissedCandidates = SelfService.encodeDismissals(SelfService.dismiss(SelfService.decodeDismissals(settings.dismissedCandidates), deviceId, createdAt, nowSec))
            candidates = candidates.filter { it.deviceId != deviceId }
            publishCandidates()
        }
    }

    /**
     * 한 방의 초대 판정 입력(iOS `roomView`·웹 `roomsView()`): 참여·정지·내 초대 commit 대기(`pendingInvite`)·명단·이번 틱 동기화.
     * 정지된 방은 어차피 대상이 아니므로 동기화된 것으로 본다(재탐색을 영영 막지 않게).
     */
    private fun roomView(h: Handle): SelfService.RoomView {
        val halted = (h.halted ?: h.store.haltReason()) != null
        val sync = runCatching { h.room.syncState() }.getOrNull()
        val joined = sync?.joined ?: false
        return SelfService.RoomView(
            h.name, joined, halted, pending = sync?.pendingInvite != null,
            roster = if (joined && sync != null) roster(h, sync.epoch) else null, synced = h.synced || halted,
        )
    }

    /** 그룹 명단(엔진 `members` roster 프레임) — epoch 가 같으면 캐시. 읽지 못하면 null(판정은 「명단 모름」으로). */
    private fun roster(h: Handle, epoch: Long): List<String>? {
        if (h.rosterEpoch == epoch && h.roster != null) return h.roster
        val list = try {
            SelfService.parseRosterFrame(h.room.dispatch("members", ByteArray(0)))
        } catch (e: Exception) {
            Log.w(TAG, "${h.name}: members: $e"); null
        }
        h.roster = list
        h.rosterEpoch = if (list != null) epoch else Long.MIN_VALUE
        return list
    }

    /**
     * 형제 기기의 `GET /v2/lobby/status?device=`(#616): 로비 키 잔량과 commit 으로 내보낸 방(`excluded_rooms`). 코어 요청과 같은 인증 헤더로
     * 허브가 직접 묻는다(코어 `MlsLobby.status` 는 이 기기만 묻는다). 응답이 없거나 200 이 아니거나 모양이 틀리면 null.
     */
    private fun lobbyPeek(target: String): SelfService.LobbyPeek? {
        val base = settings.relayUrl ?: return null
        val token = settings.accessToken?.trim()?.takeIf { it.isNotEmpty() }
        val headers = if (token == null) emptyList() else listOf(HttpHeader(ACCESS_HEADER, token))
        return try {
            val r = transport.send("GET", "$base/v2/lobby/status?device=$target", headers, null)
            if (r.status.toInt() != 200) { Log.w(TAG, "lobby status $target: ${r.status}"); null }
            else SelfService.parseLobbyStatus(String(r.body, Charsets.UTF_8))
        } catch (e: RoomException) {
            Log.w(TAG, "lobby status $target: ${e.message}"); null
        }
    }

    /** 재탐색 조회가 실패한 뒤 다시 묻지 않을 때까지(ms, 메모리) — 실패 때 틱(4초)마다 릴레이를 두드리지 않게. */
    private var rescanRetryAt = 0L

    /**
     * #616 빠진 방 주기적 재탐색(오너 D1~D3, iOS `rescanSiblingsLocked`·웹 `rescanSiblings`): 최소 6시간마다 내 다른 활성 기기가 빠진 방을
     * 형제 초대 대기열에 넣는다. commit 으로 내보낸 방(`excluded_rooms`)은 건너뛰고, 그 필드가 없는 옛 릴레이면 그 기기는 재탐색하지 않는다(fail-closed).
     * 방마다 초대 기기는 하나: 그 방의 내 기기 중 ID 최소가 바로, 나머지는 30분 뒤에도 빠져 있을 때만. 틱의 `poll` 이 끝난 뒤라 명단은 최신이다
     * (이번 틱에 동기화 못 한 방이 있으면 다음 틱에). 조회 실패는 이번 재탐색을 1분 미룬다.
     */
    private fun rescanSiblings(l: MlsLobby) {
        if (settings.siblingRescanOff) return
        val identity = l.identity()
        val siblings = SiblingRescan.siblings(me, identity)
        if (siblings.isEmpty()) return
        val now = System.currentTimeMillis()
        val state = SiblingRescan.decodeState(settings.siblingRescanState)
        if (!SiblingRescan.due(state, now) || now < rescanRetryAt) return
        val excluded = HashMap<String, List<String>?>()
        for (target in siblings) {
            val peek = lobbyPeek(target) ?: run {
                Log.w(TAG, "sibling rescan: lobby status $target failed — retry in 1 min")
                rescanRetryAt = now + SelfService.SIBLING_LOBBY_RECHECK_MS
                return
            }
            excluded[target] = peek.excludedRooms
        }
        val turn = SiblingRescan.turn(rooms.values.map(::roomView), identity, siblings, excluded, state, now)
        if (!turn.ready) return
        settings.siblingRescanState = SiblingRescan.encodeState(turn.state)
        val skipped = siblings.filter { excluded[it] == null }
        if (skipped.isNotEmpty()) Log.i(TAG, "sibling rescan: relay gave no excluded_rooms — skipped ${skipped.joinToString(",")}")
        if (turn.enqueue.isEmpty()) return
        var queue = SelfService.decodeSiblingQueue(settings.siblingQueue)
        for ((target, list) in turn.enqueue) {
            queue = SelfService.enqueueSiblingInvites(queue, target, list, now, origin = SiblingRescan.ORIGIN)
            Log.i(TAG, "sibling rescan: $target missing from ${list.joinToString(",")}")
        }
        settings.siblingQueue = SelfService.encodeSiblingQueue(queue)
    }

    /** 설정 「빠진 방 다시 찾기」(#616, 기본 켜짐). 화면 스레드에서 불러도 된다(저장만). */
    fun setSiblingRescan(on: Boolean) {
        settings.siblingRescanOff = !on
        _ui.update { it.copy(siblingRescan = on) }
        Log.i(TAG, "sibling rescan ${if (on) "on" else "off"}")
    }

    /** 승인 직후: 새 기기를 들일 방(내가 참여한·정지 아닌·명단에 없는 방)을 대기열에 적는다 — 틱마다 `processSiblingInvites` 가 시도한다. */
    private fun queueSiblingInvites(target: String) {
        val list = SelfService.siblingInviteRooms(rooms.values.map(::roomView), target)
        if (list.isEmpty()) return
        val queue = SelfService.enqueueSiblingInvites(SelfService.decodeSiblingQueue(settings.siblingQueue), target, list, System.currentTimeMillis())
        settings.siblingQueue = SelfService.encodeSiblingQueue(queue)
        Log.i(TAG, "sibling $target queued for ${list.joinToString(",")}")
    }

    /** `WelcomeDropped`(#574 후속) 뒤: 그 방의 초대를 대기열에 되돌린다(코어가 commit 과 Welcome 을 버렸으니 처음부터 다시 — 로비 키부터). */
    private fun requeueSiblingInvite(target: String, room: String) {
        val queue = SelfService.enqueueSiblingInvites(SelfService.decodeSiblingQueue(settings.siblingQueue), target, listOf(room), System.currentTimeMillis())
        settings.siblingQueue = SelfService.encodeSiblingQueue(queue)
    }

    /** 코어 초대 한 번 → `SelfService.InviteOutcome`. `Posted` 의 Welcome 은 코어가 `<room>.sync` 에 영속해 두고 다음 `poll` 이 올린다(#574 후속). */
    private fun inviteOnce(h: Handle, target: String): SelfService.InviteOutcome = try {
        when (val r = h.room.invite(target)) {
            is MlsInvite.Invited, is MlsInvite.Posted -> { Log.i(TAG, "sibling $target invited into ${h.name}: $r"); SelfService.InviteOutcome.Invited }
            is MlsInvite.NoKeyPackage -> SelfService.InviteOutcome.NoKey
            is MlsInvite.Pending, is MlsInvite.Raced -> SelfService.InviteOutcome.Retry
        }
    } catch (ex: RoomException) {
        if (ex is RoomException.Relay && ex.transient) SelfService.InviteOutcome.Retry
        else { Log.w(TAG, "sibling $target in ${h.name}: $ex"); SelfService.InviteOutcome.Failed(ex.message ?: "?") }
    }

    /**
     * 형제 기기 초대 대기열(틱 끝, #574 → #616): TTL(마지막 진행부터 24시간) 지난 항목은 알리고 버린다; 살아 있는 항목은 `SelfService.siblingInviteTurn` —
     * 형제 기기의 로비 키 잔량(`lobbyPeek`)만큼만 방마다 `MlsRoom.invite`, 잔량 0 이면 시도 없이 1분 기다리고(`recheckAt`), `NoKeyPackage`·`Pending`·
     * `Raced`·일시 오류는 남기고, 그 밖의 실패는 알리고 버린다. 재탐색이 넣은 항목(`origin`)의 포기·실패는 알리지 않는다(다음 재탐색이 다시).
     */
    private fun processSiblingInvites() {
        val queue = SelfService.decodeSiblingQueue(settings.siblingQueue)
        if (queue.isEmpty()) return
        val now = System.currentTimeMillis()
        val (live, expired) = SelfService.splitSiblingQueue(queue, now)
        for (e in expired) {
            Log.w(TAG, "sibling ${e.target}: gave up after ${SelfService.SIBLING_INVITE_TTL_MS / 3_600_000L} h without progress (${e.rooms})")
            if (e.origin != SiblingRescan.ORIGIN) notice(Strings.siblingGaveUp(e.target, e.rooms))
        }
        val next = ArrayList<SelfService.SiblingInvite>()
        val rescanned = HashSet<String>()
        var rescannedRooms = 0
        for (e in live) {
            val turn = SelfService.siblingInviteTurn(
                e, now,
                lobbyLive = { lobbyPeek(e.target)?.live },
                roomView = { room -> rooms[room]?.let(::roomView) },
                invite = { room -> rooms[room]?.let { inviteOnce(it, e.target) } ?: SelfService.InviteOutcome.Retry },
            )
            for (room in turn.invited) notice(Strings.siblingInvited(e.target, room))
            if (e.origin == SiblingRescan.ORIGIN && turn.invited.isNotEmpty()) { rescanned += e.target; rescannedRooms += turn.invited.size }
            for ((room, reason) in turn.failed) {
                Log.w(TAG, "sibling ${e.target}: invite into $room failed (giving up) — $reason")
                if (e.origin != SiblingRescan.ORIGIN) notice(Strings.siblingFailed(e.target, room, reason))
            }
            val entry = turn.entry ?: continue
            if (entry.recheckAt != null && entry.recheckAt != e.recheckAt) Log.i(TAG, "sibling ${e.target}: no lobby key left — ${entry.rooms.size} room(s) wait for a replenish")
            next += entry
        }
        settings.siblingQueue = SelfService.encodeSiblingQueue(next)
        if (rescannedRooms > 0) notice(Strings.siblingRescanned(rescanned.size, rescannedRooms))
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
            // Queued 는 다음 poll 이 다시 보낸다 — watch 가 이 방을 changed 로 알리지 않아도 다음 틱에 poll 되게 표시(#766 E, 60 s 안전망까지 밀리지 않게).
            val r = mutex.withLock { h.room.send(text.toByteArray(Charsets.UTF_8)).also { if (it is SendResult.Queued) h.synced = false } }
            when (r) {
                is SendResult.Sent -> db.insert(room, r.seq, h.room.identity(), r.clientId, MessageDb.KIND_TEXT, text, null)
                is SendResult.Queued -> notice("연결되면 보냅니다")
                is SendResult.AlreadyDelivered -> {}
            }
            _ui.update { it.copy(rooms = roomList()) }
        } catch (e: RoomException) {
            notice(if (e is RoomException.Relay && e.transient) "연결 중입니다…" else (e.message ?: "전송 안 됨"))
        }
    }

    /**
     * 첨부 열기(#366 C · #338 C 단계): v1 행은 저장된 파일 바이트 그대로, file-v2 행은 설명자로 `MlsRoom.openFileV2`(blob 받기 → 검증 →
     * 복호 — 코어). 허브 mutex **밖**에서 돈다: 큰 파일을 받는 동안 poll·보내기가 막히지 않게(`MlsRoom` 은 자체 잠금이 있고 받는 동안은
     * 그 잠금도 놓는다). 결과 바이트는 이력에 저장하지 않는다. MIME·종류는 내용으로 정한다(설명자 힌트를 믿지 않는다, FILE-V2 §4.4).
     */
    suspend fun openAttachment(room: String, seq: Long): AttachmentFiles.OpenResult = withContext(Dispatchers.IO) {
        val h = mutex.withLock { rooms[room] } ?: return@withContext AttachmentFiles.OpenFailed(Strings.attachmentOpenFailed, retry = false)
        val (kind, stored) = db.attachment(room, seq) ?: return@withContext AttachmentFiles.OpenFailed(Strings.attachmentOpenFailed, retry = false)
        try {
            val v2 = kind == MessageSchema.KIND_FILE_V2
            val name = if (v2) runCatching { fileV2Check(stored).name }.getOrNull() else null
            val bytes = if (v2) h.room.openFileV2(stored) else stored
            val sniff = fileV2Sniff(bytes)
            AttachmentFiles.Opened(bytes, sniff.mime, sniff.kind, AttachmentFiles.safeName(name, sniff.mime))
        } catch (e: RoomException) {
            Log.w(TAG, "$room seq $seq: attachment open failed (${e.javaClass.simpleName})")
            when {
                e is RoomException.Host && e.reason == "file-v2 integrity" -> AttachmentFiles.OpenFailed(Strings.attachmentDamaged, retry = true)
                e is RoomException.Relay && e.transient -> AttachmentFiles.OpenFailed(Strings.attachmentOffline, retry = true)
                e is RoomException.Relay && e.reason.contains("no_such_blob") -> AttachmentFiles.OpenFailed(Strings.attachmentGone, retry = false)
                else -> AttachmentFiles.OpenFailed(Strings.attachmentOpenFailed, retry = e is RoomException.Relay)
            }
        }
    }

    /**
     * 말풍선 썸네일을 시도할지 + 자리 크기 힌트(#698 C2). 이력만 읽는다(네트워크·허브 mutex 없음). v1 = 저장된 바이트의 내용 판별,
     * file-v2 = 설명자의 크기·MIME 힌트로 저절로 받을 범위만 좁힌다(`ThumbnailSizing.fileV2`) — 사진으로 그릴지는 받은 바이트로 정한다.
     */
    suspend fun attachmentPreview(room: String, seq: Long): ThumbnailSizing.Preview? = withContext(Dispatchers.IO) {
        val (kind, stored) = db.attachment(room, seq) ?: return@withContext null
        if (kind == MessageSchema.KIND_FILE_V2) {
            val info = runCatching { fileV2Check(stored) }.getOrNull() ?: return@withContext null
            ThumbnailSizing.fileV2(info.size.toLong(), info.mime, info.w?.toLong(), info.h?.toLong())
        } else {
            ThumbnailSizing.Preview(candidate = stored.isNotEmpty() && fileV2Sniff(stored).kind == "image")
        }
    }

    /**
     * 첨부 보내기(#366 C): `MlsRoom.sendFileV2`(봉인 → blob 업로드 → 설명자를 `file-v2-<uuid>` 로 게시 — 코어, 409 재전송도 file-v2).
     * 허브 mutex 밖(업로드가 길 수 있다). 보내졌으면 내 이력에 `file-v2` 행(본문 = 자리 표시, attachment = 설명자 — 파일 키 포함, 글로
     * 보이지 않는다). 글 보내기와 같이 `Queued` 는 안내만 한다(다음 poll 이 다시 보낸다).
     */
    fun sendAttachment(scope: CoroutineScope, room: String, bytes: ByteArray, name: String?) = scope.launch(Dispatchers.IO) {
        val h = mutex.withLock { rooms[room] } ?: return@launch
        notice(Strings.attachmentSending)
        try {
            val out = h.room.sendFileV2(bytes, null, AttachmentFiles.sendName(name))
            when (val r = out.result) {
                is SendResult.Sent -> {
                    db.insert(room, r.seq, h.room.identity(), r.clientId, MessageSchema.KIND_FILE_V2, Strings.attachmentPlaceholder(out.size.toLong()), out.descriptor)
                    clearNotice()
                }
                is SendResult.Queued -> {
                    mutex.withLock { h.synced = false } // 글 보내기와 같이 다음 틱에 이 방을 poll(#766 E)
                    notice("연결되면 보냅니다")
                }
                is SendResult.AlreadyDelivered -> clearNotice()
            }
            _ui.update { it.copy(rooms = roomList()) }
        } catch (e: RoomException) {
            Log.w(TAG, "$room: attachment send failed (${e.javaClass.simpleName})")
            notice(
                when {
                    e is RoomException.Relay && e.transient -> "연결 중입니다…"
                    e is RoomException.Relay && AttachmentFiles.isSizeRefusal(e.reason) -> Strings.attachmentTooLarge
                    else -> Strings.attachmentSendFailed
                },
            )
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
            _ui.update { it.copy(rooms = roomList()) }
        }
    }

    /** 설정 저장 뒤(세션 값 포함) 다시 접촉. 새 세션이면 `/v2/me` 와 후보 게시도 처음부터. */
    fun reconfigure(scope: CoroutineScope) = scope.launch(Dispatchers.IO) {
        linkPreviews.resetSites() // 새 세션 — 사이트 목록은 준비 단계에서 다시 받는다
        roomOrder.resetSession() // 새 세션 — 방 순서도 준비 단계에서 바로 다시 묻는다(404 판정도 지운다)
        mutex.withLock { applyAccessToken(); me = null; meUnsupported = false; selfServiceUnsupported = false; nextPostAt = 0L; fullSweepAt = null; auxAt = null; _ui.update { it.copy(phase = Phase.Starting) }; probe() }
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
     * 웹 안내(`BuildConfig.DELETE_ACCOUNT_URL`, docs/hande/delete-account.md)로 요청한다. 처음 설정 뒤 `start` 를 다시 부를 수 있도록 `loop` 를 멈춘다.
     */
    fun wipeDevice(scope: CoroutineScope) = scope.launch(Dispatchers.IO) {
        loop.stop()
        mutex.withLock {
            Log.i(TAG, "wipe: closing ${rooms.size} rooms + lobby, deleting local state")
            rooms.values.forEach { h -> runCatching { h.room.close() }.onFailure { e -> Log.w(TAG, "wipe: close ${h.name}: $e") } }
            rooms.clear()
            runCatching { lobby?.close() }.onFailure { e -> Log.w(TAG, "wipe: close lobby: $e") }
            lobby = null
            lobbyStore = null
            me = null; meUnsupported = false; selfServiceUnsupported = false; nextPostAt = 0L
            candidates = emptyList(); candidateRevision = null
            busy.clear(); candidateMessages.clear()
            ticks = 0
            fullSweepAt = null; auxAt = null
            runCatching { db.wipe() }.onFailure { e -> Log.w(TAG, "wipe: messages.db: $e") }
            if (!dir.deleteRecursively()) Log.w(TAG, "wipe: some files under ${dir.name} could not be deleted")
            dir.mkdirs()
            orderScope.coroutineContext.cancelChildren()
            roomOrder.clear()
            settings.wipe()
            linkPreviews.clear()
            AttachmentThumbs.clear() // #698 C2: 메모리의 첨부 썸네일
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
        /** host-core `api.rs` 가 릴레이 요청에 붙이는 인증 헤더 이름 그대로(`OkHttpTransport.ACCESS_HEADER` 와 같다). */
        const val ACCESS_HEADER = "Cf-Access-Jwt-Assertion"
        /** 엣지 인증 실패 모양: `relay status 301|302|303|307|308|401|403` · `relay error 401: …`. */
        val EDGE_AUTH = Regex("relay (status (30[12378]|401|403)\\b|error 401\\b)")
        const val POLL_MS = 4_000L
        /** #755 `watch` 대기 — `OkHttpTransport` readTimeout(15 s)보다 짧게. 릴레이 상한은 25 s. */
        const val WATCH_WAIT_MS = 12_000L
        /** 틱 사이 최소 간격(변화가 몰려도 틱은 초당 1번까지). */
        const val MIN_TICK_GAP_MS = 1_000L
        /** 릴레이 `maxWatchRooms`. */
        const val WATCH_MAX_ROOMS = 64
        /** `/v2/watch` 미지원 판정을 다시 확인하는 틱 수(4 s 폴링 기준 ≈ 5분). */
        const val WATCH_REPROBE_TICKS = 75
        const val LOBBY_TARGET = 8
        const val REPLENISH_EVERY = 15 // ≈ 1분
        /** `GET /v2/me` 주기(#574, 웹 `ME_EVERY_TICKS`) — 체인이 바뀐 직후(승인·역할)에는 바로 다시 읽는다. */
        const val ME_EVERY_TICKS = 4
        fun sha256Hex(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
