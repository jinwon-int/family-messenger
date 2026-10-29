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
    /** 형제 기기 초대 대기열의 수명 — 새 기기가 활성이 된 뒤 로비 키를 올릴 때까지 기다리되, 영원히는 아니다. */
    const val SIBLING_INVITE_TTL_MS = 30 * 60_000L
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

    /** 초대 후보 방의 로컬 상태(허브 `Handle` 의 공개 필드). */
    data class RoomView(val room: String, val joined: Boolean, val halted: Boolean)

    /** 새 형제 기기를 초대할 방: 내가 참여했고 정지가 아닌 방. (대기 commit·이미 명단에 있음은 코어 `invite` 가 `Pending`/오류로 답한다.) */
    fun siblingInviteRooms(rooms: List<RoomView>): List<String> = rooms.filter { it.joined && !it.halted }.map { it.room }

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
    // 적어 두고 틱마다 다시 시도한다; TTL 이 지나면 알리고 버린다. 저장 형식: 줄마다 `target|sinceMs|room1,room2`(식별자에 `|`·`,` 없음).

    data class SiblingInvite(val target: String, val rooms: List<String>, val since: Long)

    private val IDENT = Regex("^[A-Za-z0-9_-]{1,64}$")

    fun decodeSiblingQueue(text: String?): List<SiblingInvite> {
        if (text.isNullOrBlank()) return emptyList()
        return text.lines().mapNotNull { line ->
            val parts = line.split('|')
            if (parts.size != 3) return@mapNotNull null
            val target = parts[0].takeIf { IDENT.matches(it) } ?: return@mapNotNull null
            val since = parts[1].toLongOrNull() ?: return@mapNotNull null
            val rooms = parts[2].split(',').filter { IDENT.matches(it) }
            SiblingInvite(target, rooms, since)
        }
    }

    fun encodeSiblingQueue(queue: List<SiblingInvite>): String =
        queue.joinToString("\n") { "${it.target}|${it.since}|${it.rooms.joinToString(",")}" }

    /** 대기열에 (target, rooms) 를 넣는다 — 같은 target 이 있으면 방을 합치고 시각은 유지. 방이 없으면 그대로. */
    fun enqueueSiblingInvites(queue: List<SiblingInvite>, target: String, rooms: List<String>, now: Long): List<SiblingInvite> {
        val add = rooms.filter { it.isNotEmpty() }.distinct()
        if (add.isEmpty()) return queue
        val existing = queue.firstOrNull { it.target == target }
        return if (existing != null) queue.map { if (it === existing) it.copy(rooms = (it.rooms + add).distinct()) else it }
        else queue + SiblingInvite(target, add, now)
    }

    /** 처리할 것(first)과 포기할 것(second, TTL 지남)으로 나눈다. */
    fun splitSiblingQueue(queue: List<SiblingInvite>, now: Long, ttl: Long = SIBLING_INVITE_TTL_MS): Pair<List<SiblingInvite>, List<SiblingInvite>> =
        queue.partition { now - it.since <= ttl }

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
