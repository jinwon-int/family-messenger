// 새 기기 셀프서비스(#574 PR 4) — 순수 판정·조립 함수. 웹 `web/hande/self-service.js` 와 1:1(같은 이름·같은 규칙), android.* 없음 →
// JVM 단위 테스트(`SelfServiceTest`)로 고정한다. 와이어·서명은 Rust 코어(`MlsLobby.me/postCandidate/listCandidates/approve/setRoles`,
// `MlsRoom.invite`)가 하고, 여기는 **누가·무엇을** 할 수 있는지만 정한다.
//
// 서버 계약(server/devices.go · me.go · lobby.go, DEVICES-V4 「셀프서비스 라우트」):
//   누가 서명할 수 있나(devicepolicy.VerifyApproval/VerifyRoles): 이 기기가 활성이고, (registrar 이거나 같은 actor 에 활성 registrar 가 없을 때).
//   마지막 registrar 는 스스로 해제할 수 없다(다른 기기에 먼저 부여). 승인은 같은 actor 사이에서만.
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.mls.MlsCandidate
import com.seoyoon_family.hande.mls.MlsMe
import com.seoyoon_family.hande.mls.MlsMeDevice

object SelfService {
    const val ROLE_REGISTRAR = "registrar"
    const val STATUS_ACTIVE = "active"
    /**
     * 형제 기기 초대 대기열의 수명 — **마지막 진행**(넣은 때·초대가 하나라도 성공한 때)부터 잰다(#616, iOS `siblingInviteTTL`·웹과 같다).
     * 30분 고정이던 때는 새 기기(백그라운드 크롬 탭)가 로비 키를 15시간 뒤에야 보충해 9개 방이 영영 빠졌다.
     */
    const val SIBLING_INVITE_TTL_MS = 24 * 60 * 60_000L
    /** #616: 형제 기기 로비 키 잔량이 0 일 때 다음에 다시 물을 때까지(틱마다 묻지 않게). */
    const val SIBLING_LOBBY_RECHECK_MS = 60_000L
    /** 후보 게시의 재게시 여유: 만료(10분) 이만큼 전에 다시 올린다. */
    const val CANDIDATE_REPOST_MARGIN_MS = 5 * 60_000L
    /** 후보 우편함 행의 수명(릴레이 `server/devices.go` `candidateTTL` = 10분), 초 — 「무시」 항목도 이만큼 뒤에 만료된다. */
    const val CANDIDATE_TTL_SECONDS = 10 * 60L

    private val HEX64 = Regex("^[a-f0-9]{64}$")

    /** 등록 화면 모드(웹 `enrollModeFrom` 의 세 값). */
    enum class EnrollMode { OPERATOR, SIBLING, ID_TAKEN }

    fun isRegistrar(d: MlsMeDevice): Boolean = ROLE_REGISTRAR in d.roles
    fun isActive(d: MlsMeDevice): Boolean = d.status == STATUS_ACTIVE

    /** /v2/me 의 내 기기 기록(없으면 null — 옛 릴레이거나 아직 체인에 없는 기기). */
    fun recordOf(me: MlsMe?, device: String): MlsMeDevice? = me?.devices?.firstOrNull { it.deviceId == device }

    /** 이 actor 에 활성 registrar 가 하나라도 있나(devicepolicy.HasRegistrar). */
    fun actorHasRegistrar(me: MlsMe?, actor: String): Boolean =
        me?.devices.orEmpty().any { it.actor == actor && isActive(it) && isRegistrar(it) }

    /**
     * 이 기기가 같은 actor 의 새 기기를 승인(E2)하거나 역할(E5)에 서명할 수 있나:
     * 활성이고, registrar 이거나 그 actor 에 활성 registrar 가 없다(#574 이전 체인의 「활성 기기면 누구나」 규칙).
     */
    fun canApprove(me: MlsMe?, device: String): Boolean {
        val rec = recordOf(me, device) ?: return false
        if (!isActive(rec)) return false
        return isRegistrar(rec) || !actorHasRegistrar(me, rec.actor)
    }

    /** 로비 Welcome 을 보낸 기기(`from`)가 내 형제 기기인가 — 내가 아니고, 체인에 그 ID 의 활성 기록이 있고, 같은 actor. */
    fun isSibling(from: String?, me: MlsMe?, actor: String?, device: String): Boolean {
        if (from.isNullOrEmpty() || from == device || actor.isNullOrEmpty()) return false
        val rec = recordOf(me, from) ?: return false
        return rec.actor == actor && isActive(rec)
    }

    /** 우편함에서 내 actor 의 후보만(모양이 온전한 것만). */
    fun candidatesFor(list: List<MlsCandidate>, actor: String): List<MlsCandidate> =
        list.filter { it.actor == actor && HEX64.matches(it.signingKey) && HEX64.matches(it.fingerprint) }

    /** 역할 목록에 registrar 를 넣거나 빼서 **완전한 정렬 목록**으로(서버 CanonicalRoles 와 같은 모양). */
    fun nextRoles(roles: List<String>, grant: Boolean): List<String> {
        val set = roles.toMutableSet()
        if (grant) set += ROLE_REGISTRAR else set -= ROLE_REGISTRAR
        return set.sorted()
    }

    /** 「내 기기」 화면의 한 줄: 체인 기록 + 이 기기가 그 기기에 할 수 있는 역할 변경. */
    data class DeviceRow(
        val deviceId: String,
        val actor: String,
        val fingerprint: String,
        val status: String,
        val roles: List<String>,
        val registrar: Boolean,
        val isSelf: Boolean,
        /** registrar 부여 가능: 서명 가능 · 대상 활성 · 같은 actor · 아직 registrar 아님. */
        val grant: Boolean,
        /** registrar 해제 가능: 서명 가능 · 대상 활성 · 같은 actor · registrar · 해제 뒤에도 활성 registrar 가 남음. */
        val release: Boolean,
        /** 해제하면 actor 에 registrar 가 없어진다 — 먼저 다른 기기에 부여. */
        val lastRegistrar: Boolean,
    )

    data class RolesView(val canSign: Boolean, val actor: String?, val devices: List<DeviceRow>)

    /**
     * 「내 기기」 행: 체인의 내 subject 기기 전부(폐기 포함, **이 기기 먼저**) + 역할 변경 가능 여부(웹 `rolesActions` 와 같은 규칙).
     * - 서명 가능 = canApprove(E5 도 같은 규칙).
     * - 부여: 대상이 활성·같은 actor·아직 registrar 가 아닐 때. 해제: 대상이 활성·같은 actor·registrar 이고 다른 활성 registrar 가 남을 때.
     */
    fun rolesActions(me: MlsMe?, device: String): RolesView {
        val all = me?.devices.orEmpty()
        val self = recordOf(me, device)
        val canSign = canApprove(me, device)
        val actor = self?.actor
        val activeRegistrars = all.count { it.actor == actor && isActive(it) && isRegistrar(it) }
        val rows = all.map { d ->
            val registrar = isRegistrar(d)
            val eligible = canSign && isActive(d) && d.actor == actor
            val release = eligible && registrar && activeRegistrars - 1 > 0
            DeviceRow(
                deviceId = d.deviceId, actor = d.actor, fingerprint = d.fingerprint, status = d.status, roles = d.roles, registrar = registrar,
                isSelf = d.deviceId == device, grant = eligible && !registrar, release = release, lastRegistrar = eligible && registrar && !release,
            )
        }
        return RolesView(canSign, actor, rows.sortedByDescending { it.isSelf })
    }

    /**
     * 초대 후보 방의 로컬 상태(허브 `Handle` 의 공개 필드). `pending` = 내 초대 commit 이 아직 echo 전(`RoomSyncState.pendingInvite`),
     * `roster` = 그룹 명단(엔진 `members`, 모르면 null), `synced` = 이번 틱의 `poll` 이 성공했나(#616 재탐색은 명단이 최신일 때만).
     */
    data class RoomView(
        val room: String, val joined: Boolean, val halted: Boolean,
        val pending: Boolean = false, val roster: List<String>? = null, val synced: Boolean = true,
    )

    /**
     * 새 형제 기기를 초대할 방: 내가 참여했고, 정지가 아니고, 내 commit 이 대기 중이 아니고, (`target` 을 주면) 아직 명단에 없는 방.
     * iOS `siblingInviteRooms(_:target:)`·웹 `siblingInviteRooms` 와 같은 규칙.
     */
    fun siblingInviteRooms(rooms: List<RoomView>, target: String? = null): List<String> =
        rooms.filter { it.joined && !it.halted && !it.pending && !(target != null && it.roster?.contains(target) == true) }.map { it.room }

    /**
     * `POST /v2/devices/candidates` 의 응답 → 등록 화면 모드.
     * 201 = 형제 기기가 승인한다(SIBLING); 409 device_exists = 이 ID 는 다시 쓸 수 없다(ID_TAKEN);
     * 403 first_device_out_of_band·subject_mismatch, 404(옛 릴레이·접근 인증 꺼짐), 그 밖 = 운영자 흐름(OPERATOR).
     */
    fun enrollModeFrom(status: Int, code: String): EnrollMode = when {
        status == 201 -> EnrollMode.SIBLING
        status == 409 && code == "device_exists" -> EnrollMode.ID_TAKEN
        else -> EnrollMode.OPERATOR
    }

    /** 후보를 다시 올릴 시각: 만료 5분 전(만료를 모르면 지금부터 5분 뒤). */
    fun nextPostAt(expiresAtMs: Long?, now: Long): Long =
        if (expiresAtMs != null && expiresAtMs > 0L) expiresAtMs - CANDIDATE_REPOST_MARGIN_MS else now + CANDIDATE_REPOST_MARGIN_MS

    /** 사람이 읽는 지문: 4자씩 띄우고 4묶음마다 줄을 바꾼다(64 hex → 4줄). 64자가 아니면 그대로. */
    fun groupedFingerprint(fingerprint: String): String {
        if (fingerprint.length != 64) return fingerprint
        return fingerprint.chunked(16).joinToString("\n") { line -> line.chunked(4).joinToString(" ") }
    }

    // ---- 형제 기기 초대 대기열(SharedPreferences `sibling_invites`, 웹 localStorage `hande:sibling-invites:<device>` 와 같은 뜻) ----
    // 새 기기는 활성이 된 다음 틱에야 로비 키를 올리므로 승인 직후의 초대는 「키 패키지 없음」으로 실패한다. 승인한 기기가 방 목록을
    // 적어 두고 틱마다 다시 시도한다; TTL(마지막 진행부터) 이 지나면 알리고 버린다.
    // 저장 형식: 줄마다 `target|sinceMs|room1,room2` — #616 부터 진행 정보가 있으면 `|progressMs|recheckAtMs|origin` 세 칸을 더 붙인다(빈 칸 = 없음).
    // 옛 3칸 줄도 그대로 읽는다(식별자에 `|`·`,` 없음).

    /**
     * 대기열 항목. `progress` = 마지막으로 초대가 성공한 시각(ms, TTL 은 이것 — 없으면 `since` — 부터), `recheckAt` = 형제 기기 로비 키가 0 이라
     * 이 시각(ms)까지는 잔량도 묻지 않는다, `origin` = 재탐색(`SiblingRescan.ORIGIN`)이 넣은 항목이면 포기·실패해도 알리지 않는다(다음 재탐색이 다시).
     */
    data class SiblingInvite(
        val target: String, val rooms: List<String>, val since: Long,
        val progress: Long? = null, val recheckAt: Long? = null, val origin: String? = null,
    )

    private val IDENT = Regex("^[A-Za-z0-9_-]{1,64}$")

    fun decodeSiblingQueue(text: String?): List<SiblingInvite> {
        if (text.isNullOrBlank()) return emptyList()
        return text.lines().mapNotNull { line ->
            val parts = line.split('|')
            if (parts.size != 3 && parts.size != 6) return@mapNotNull null
            val target = parts[0].takeIf { IDENT.matches(it) } ?: return@mapNotNull null
            val since = parts[1].toLongOrNull() ?: return@mapNotNull null
            val rooms = parts[2].split(',').filter { IDENT.matches(it) }
            if (parts.size == 3) return@mapNotNull SiblingInvite(target, rooms, since)
            fun optLong(s: String): Pair<Boolean, Long?> = if (s.isEmpty()) true to null else s.toLongOrNull().let { (it != null) to it }
            val (okP, progress) = optLong(parts[3])
            val (okR, recheckAt) = optLong(parts[4])
            if (!okP || !okR) return@mapNotNull null
            val origin = parts[5].takeIf { it.isNotEmpty() }
            if (origin != null && !IDENT.matches(origin)) return@mapNotNull null
            SiblingInvite(target, rooms, since, progress, recheckAt, origin)
        }
    }

    fun encodeSiblingQueue(queue: List<SiblingInvite>): String =
        queue.joinToString("\n") {
            val base = "${it.target}|${it.since}|${it.rooms.joinToString(",")}"
            if (it.progress == null && it.recheckAt == null && it.origin == null) base
            else "$base|${it.progress ?: ""}|${it.recheckAt ?: ""}|${it.origin ?: ""}"
        }

    /** 대기열에 (target, rooms) 를 넣는다 — 같은 target 이 있으면 방을 합치고 시각·출처는 유지. 방이 없으면 그대로. */
    fun enqueueSiblingInvites(queue: List<SiblingInvite>, target: String, rooms: List<String>, now: Long, origin: String? = null): List<SiblingInvite> {
        val add = rooms.filter { it.isNotEmpty() }.distinct()
        if (add.isEmpty()) return queue
        val existing = queue.firstOrNull { it.target == target }
        return if (existing != null) queue.map { if (it === existing) it.copy(rooms = (it.rooms + add).distinct()) else it }
        else queue + SiblingInvite(target, add, now, origin = origin)
    }

    /** 처리할 것(first)과 포기할 것(second, 마지막 진행 `progress` — 없으면 `since` — 부터 TTL 지남)으로 나눈다. */
    fun splitSiblingQueue(queue: List<SiblingInvite>, now: Long, ttl: Long = SIBLING_INVITE_TTL_MS): Pair<List<SiblingInvite>, List<SiblingInvite>> =
        queue.partition { now - (it.progress ?: it.since) <= ttl }

    /**
     * #616: 이번 차례에 초대를 시도할 방 수. 방마다 형제 기기의 로비 키를 하나씩 쓰는데(상한 8), 17개 방을 한꺼번에 돌면 9번째부터
     * 「키 패키지 없음」만 쌓인다. `live` = 형제 기기 `GET /v2/lobby/status` — null(옛 릴레이·오류)이면 제한 없이 예전처럼.
     */
    fun budget(live: Int?): Int = if (live == null) Int.MAX_VALUE else maxOf(0, live)

    /** 방 하나에 초대를 시도한 결과(허브가 코어 `MlsInvite`·`RoomException` 을 이 넷으로 옮긴다). */
    sealed class InviteOutcome {
        /** `Invited`·`Posted` — 끝(Welcome 은 코어가 echo 뒤 올린다). */
        object Invited : InviteOutcome()
        /** `NoKeyPackage` — 남기고, 이번 차례 예산을 0 으로(잔량 수치가 낡았다). */
        object NoKey : InviteOutcome()
        /** `Pending`·`Raced`·일시 오류 — 남기고 다음 차례에. */
        object Retry : InviteOutcome()
        /** 다시 시도하지 않을 실패(알림). */
        data class Failed(val reason: String) : InviteOutcome()
    }

    /** 항목 하나의 이번 차례 결과. `entry` = 다음 대기열 항목(남은 방이 없으면 null). */
    data class InviteTurn(val entry: SiblingInvite?, val invited: List<String> = emptyList(), val failed: List<Pair<String, String>> = emptyList())

    /**
     * #616: 대기열 항목 하나의 이번 차례(iOS `SiblingInviteQueue.turn`·웹 `siblingInviteTurn` 과 같은 규칙 — 코어·릴레이 없이 테스트한다).
     * - `recheckAt` 전이면 아무것도 묻지 않는다. 아니면 `lobbyLive()`(형제 기기 잔량, null = 모름)만큼만 초대하고, 0 이면 시도 없이 `recheckAt` 까지 기다린다.
     * - `roomView(room)` → 판정 입력(null = 이 기기에 없는 방). 내 commit 대기인 방은 남기고, 이미 명단에 있음·정지·참여 안 함은 끝.
     * - 초대가 하나라도 성공하면 `progress` = now(TTL 이 다시 시작된다).
     */
    fun siblingInviteTurn(
        e: SiblingInvite, now: Long, lobbyLive: () -> Int?, roomView: (String) -> RoomView?, invite: (String) -> InviteOutcome,
    ): InviteTurn {
        val recheck = e.recheckAt
        if (recheck != null && now < recheck) return InviteTurn(e)
        var budget = budget(lobbyLive())
        var starved = budget == 0
        val remaining = ArrayList<String>()
        val invited = ArrayList<String>()
        val failed = ArrayList<Pair<String, String>>()
        for (room in e.rooms) {
            val view = roomView(room) ?: continue   // 이 기기에서 사라진 방
            if (siblingInviteRooms(listOf(view), e.target).isEmpty()) {
                if (view.pending && view.joined && !view.halted) remaining += room   // 내 commit 대기 → 다음 차례
                continue   // 이미 명단에 있음 / 정지 / 참여 안 함 — 끝
            }
            if (budget <= 0) { remaining += room; continue }   // 이번 차례에 쓸 로비 키가 없다
            budget -= 1
            when (val r = invite(room)) {
                InviteOutcome.Invited -> invited += room
                InviteOutcome.NoKey -> { remaining += room; budget = 0; starved = true }
                InviteOutcome.Retry -> remaining += room
                is InviteOutcome.Failed -> failed += room to r.reason
            }
        }
        if (remaining.isEmpty()) return InviteTurn(null, invited, failed)
        val progressed = invited.isNotEmpty()
        val next = e.copy(
            rooms = remaining,
            progress = if (progressed) now else e.progress,
            recheckAt = if (starved && !progressed) now + SIBLING_LOBBY_RECHECK_MS else null,
        )
        return InviteTurn(next, invited, failed)
    }

    // ---- 릴레이 응답 파싱(#616) ----

    /** `GET /v2/lobby/status?device=` 에서 쓰는 두 값. `excludedRooms` = null 이면 그 필드가 없는 옛 릴레이(재탐색은 그 기기를 건너뛴다). */
    data class LobbyPeek(val live: Int, val excludedRooms: List<String>?)

    /** 응답 본문 → `LobbyPeek`. 모양이 틀리면(`live` 가 음수 아닌 정수가 아님 · `excluded_rooms` 가 배열이 아님) null. 형식이 틀린 방 ID 는 버린다. */
    fun parseLobbyStatus(json: String): LobbyPeek? {
        if (json.length > 64 * 1024) return null
        val doc = (try { StrictJson(json).parseDocument() } catch (_: StrictJson.Malformed) { null }) as? Map<*, *> ?: return null
        val live = (doc["live"] as? StrictJson.Num)?.value ?: return null
        if (live < 0 || live != Math.floor(live) || live > Int.MAX_VALUE) return null
        val raw = doc["excluded_rooms"]
        val excluded = when (raw) {
            null, StrictJson.Null -> null
            is List<*> -> raw.filterIsInstance<String>().filter { IDENT.matches(it) }.distinct()
            else -> return null
        }
        return LobbyPeek(live.toInt(), excluded)
    }

    /**
     * 엔진 `members` 의 roster 프레임(host-core `policy::parse_roster`) → 기기 ID 목록: `u32 LE count`, 항목마다 `u32 LE len ‖ id(UTF-8) ‖ 32바이트 키`.
     * 잘렸거나 남는 바이트가 있으면 null.
     */
    fun parseRosterFrame(bytes: ByteArray): List<String>? {
        var at = 0
        fun u32(): Long? {
            if (bytes.size - at < 4) return null
            val v = (bytes[at].toLong() and 0xff) or ((bytes[at + 1].toLong() and 0xff) shl 8) or
                ((bytes[at + 2].toLong() and 0xff) shl 16) or ((bytes[at + 3].toLong() and 0xff) shl 24)
            at += 4
            return v
        }
        val count = u32() ?: return null
        if (count > 4096) return null
        val out = ArrayList<String>(count.toInt().coerceAtMost(64))
        repeat(count.toInt()) {
            val n = u32() ?: return null
            if (n > bytes.size - at || bytes.size - at - n < 32) return null
            out += String(bytes, at, n.toInt(), Charsets.UTF_8)
            at += n.toInt() + 32
        }
        return if (at == bytes.size) out else null
    }

    // ---- 「무시」한 후보(SharedPreferences `dismissed_candidates`, #574 후속) ----
    // 웹은 페이지 세션 메모리(`dismissedCandidates` Set)지만 앱은 프로세스가 자주 죽으므로 영속한다. 키는 **기기 ID**: 새 기기는 만료 5분 전마다
    // 같은 ID 로 다시 올리고 릴레이는 그때 `created_at` 을 갱신하므로(devices.go upsert) (ID, created_at) 쌍으로 맞추면 5분마다 카드가 되살아난다.
    // 항목은 무시한 후보의 `created_at` + TTL(10분, 릴레이 시계·초) 에 만료한다 — 그 행이 우편함에서 사라지는 시각과 같다. 그 뒤 같은 ID 가
    // 또 올라오면(아직 기다리는 새 기기) 카드가 다시 보인다 — 영영 숨기지는 않는다. 저장 형식: 줄마다 `deviceId|createdAtSec`.

    data class Dismissal(val deviceId: String, val createdAt: Long)

    fun decodeDismissals(text: String?): List<Dismissal> {
        if (text.isNullOrBlank()) return emptyList()
        return text.lines().mapNotNull { line ->
            val parts = line.split('|')
            if (parts.size != 2) return@mapNotNull null
            val id = parts[0].takeIf { IDENT.matches(it) } ?: return@mapNotNull null
            val at = parts[1].toLongOrNull() ?: return@mapNotNull null
            Dismissal(id, at)
        }
    }

    fun encodeDismissals(list: List<Dismissal>): String = list.joinToString("\n") { "${it.deviceId}|${it.createdAt}" }

    /** 아직 살아 있는 항목만(`createdAt + ttl > nowSec`). */
    fun pruneDismissals(list: List<Dismissal>, nowSec: Long, ttlSec: Long = CANDIDATE_TTL_SECONDS): List<Dismissal> =
        list.filter { it.createdAt + ttlSec > nowSec }

    /**
     * 후보를 무시한다: 만료된 항목을 걷어내고 같은 ID 의 항목을 이 후보의 `created_at` 으로 바꾼다. 릴레이가 `created_at` 을 주지 않으면(0 이하)
     * 지금(`nowSec`)부터 TTL 동안 숨긴다.
     */
    fun dismiss(list: List<Dismissal>, deviceId: String, createdAt: Long, nowSec: Long, ttlSec: Long = CANDIDATE_TTL_SECONDS): List<Dismissal> {
        val at = if (createdAt > 0L) createdAt else nowSec
        return pruneDismissals(list, nowSec, ttlSec).filter { it.deviceId != deviceId } + Dismissal(deviceId, at)
    }

    /** 이 ID 의 살아 있는 「무시」 항목이 있나. */
    fun isDismissed(list: List<Dismissal>, deviceId: String, nowSec: Long, ttlSec: Long = CANDIDATE_TTL_SECONDS): Boolean =
        pruneDismissals(list, nowSec, ttlSec).any { it.deviceId == deviceId }
}

/**
 * 빠진 방 주기적 재탐색(#616, 오너 결정 D1~D3) — iOS `SiblingRescan`·웹 `siblingRescanTurn` 과 같은 규칙.
 * 승인할 때 한 번 만든 대기열은 하루 뒤 포기하거나 저장값이 사라지면 다시 생기지 않는다. 그래서 앱이 틱을 도는 동안 최소 6시간마다
 * 「내 다른 활성 기기가 빠진 방」을 다시 계산해 같은 대기열(잔량 예산·진행 기준 TTL)에 넣는다.
 * D1: commit 으로 내보낸 방(`excluded_rooms`)만 건너뛴다 — 한 번도 안 들어간 방은 대상. 그 필드가 없으면(옛 릴레이) 그 기기는 건너뛴다(fail-closed).
 * 방마다 초대 기기는 하나: 그 방의 내 기기 중 ID 가 가장 작은 기기가 바로, 나머지는 30분 지나도 빠져 있을 때만.
 */
object SiblingRescan {
    /** D3: 마지막 재탐색 뒤 최소 간격. */
    const val INTERVAL_MS = 6 * 60 * 60_000L
    /** 내가 리더가 아닌 방은 이만큼 지나도 빠져 있을 때만. */
    const val DEFERRAL_MS = 30 * 60_000L
    /** 대기열 항목 출처 표시. */
    const val ORIGIN = "rescan"

    /** `last` = 마지막 실행 시각(ms), `pending` = {"target|room": 처음 빠진 것을 본 시각(ms)}(내가 리더가 아닌 방). */
    data class State(val last: Long? = null, val pending: Map<String, Long> = emptyMap())

    /** false = 참여한 방 중 이번 틱에 동기화 안 된 방이 있어 아무것도 안 했다(상태 그대로, 다음 틱에). */
    data class Turn(val ready: Boolean, val enqueue: List<Pair<String, List<String>>>, val state: State)

    private val IDENT = Regex("^[A-Za-z0-9_-]{1,64}$")

    /** 저장 형식(SharedPreferences `sibling_rescan`): 첫 줄 `last`(없으면 빈 줄), 그 뒤 줄마다 `target|room|seenMs`. 깨진 값은 빈 상태·깨진 줄은 버린다. */
    fun decodeState(text: String?): State {
        if (text.isNullOrEmpty()) return State()
        val lines = text.split('\n')
        val head = lines.first()
        val last = if (head.isEmpty()) null else head.toLongOrNull() ?: return State()
        val pending = LinkedHashMap<String, Long>()
        for (line in lines.drop(1)) {
            val p = line.split('|')
            if (p.size != 3 || !IDENT.matches(p[0]) || !IDENT.matches(p[1])) continue
            val seen = p[2].toLongOrNull() ?: continue
            pending["${p[0]}|${p[1]}"] = seen
        }
        return State(last, pending)
    }

    fun encodeState(state: State): String =
        (listOf(state.last?.toString() ?: "") + state.pending.map { (k, v) -> "$k|$v" }).joinToString("\n")

    /** 내 actor 의 다른 활성 기기 ID(정렬). 내 기록이 체인에 없거나 활성이 아니면 빈 목록. */
    fun siblings(me: MlsMe?, device: String): List<String> {
        val devices = me?.devices.orEmpty()
        val mine = devices.firstOrNull { it.deviceId == device } ?: return emptyList()
        if (!SelfService.isActive(mine) || mine.actor.isEmpty()) return emptyList()
        return devices.filter { it.deviceId != device && it.actor == mine.actor && SelfService.isActive(it) }.map { it.deviceId }.sorted()
    }

    /** 지금 재탐색할 차례인가 — 한 번도 안 했거나 간격이 지났거나, 미뤄 둔 방의 30분이 찼을 때. */
    fun due(state: State, now: Long): Boolean {
        val last = state.last ?: return true
        if (now - last >= INTERVAL_MS) return true
        return state.pending.values.any { now - it >= DEFERRAL_MS }
    }

    /** 재탐색 한 번(순수). `excluded[target]` 이 null(옛 릴레이·조회 없음)이면 그 기기는 건너뛴다. */
    fun turn(rooms: List<SelfService.RoomView>, device: String, siblings: List<String>, excluded: Map<String, List<String>?>, state: State, now: Long): Turn {
        if (rooms.any { it.joined && !it.synced }) return Turn(false, emptyList(), state)
        val mine = (listOf(device) + siblings).toSet()
        val pending = LinkedHashMap<String, Long>()
        val enqueue = ArrayList<Pair<String, List<String>>>()
        for (target in siblings) {
            val skipped = excluded[target] ?: continue   // fail-closed
            val out = skipped.toSet()
            val take = ArrayList<String>()
            for (roomId in SelfService.siblingInviteRooms(rooms, target)) {
                if (roomId in out) continue
                val view = rooms.firstOrNull { it.room == roomId } ?: continue
                val present = view.roster.orEmpty().filter { it in mine }
                val leader = (listOf(device) + present).minOrNull() ?: device
                if (leader == device) { take += roomId; continue }
                val key = "$target|$roomId"
                val seen = state.pending[key] ?: now
                if (now - seen >= DEFERRAL_MS) take += roomId else pending[key] = seen
            }
            if (take.isNotEmpty()) enqueue += target to take
        }
        return Turn(true, enqueue, State(now, pending))
    }
}
