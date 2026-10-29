// 테스트 전용 in-memory 릴레이(`ios-ffi/tests/support/mod.rs` 의 Relay 와 같은 규칙): v2 events 라우트 — GET 페이지(Welcome 은 대상에게만),
// POST(client_id dedup · epoch 불일치 409 cas_mismatch · commit 은 epoch+1) — 에 3c 의 기기 수준 라우트(로비 key package · 방 목록 · 방 닫기 ·
// 푸시 등록)와 #574 의 기기 셀프서비스(`/v2/me` · 후보 우편함 · 승인 · 역할 — 체인 대역은 revision CAS·subject 바인딩·registrar 규칙만,
// Ed25519 검증은 길이만)를 더했다. MLS 검증 없음, 순서 매기기만. JSON 은 코어가 만든 고정 필드만 정규식으로 읽는다(테스트 외 사용 금지).
package com.seoyoon_family.hande.host

import com.seoyoon_family.hande.mls.HttpHeader
import com.seoyoon_family.hande.mls.HttpResponse
import com.seoyoon_family.hande.mls.HttpTransport
import com.seoyoon_family.hande.mls.RoomException
import java.security.MessageDigest
import java.util.Base64

class InMemoryRelay(private val base: String) : HttpTransport {
    data class Row(val seq: Long, val device: String, val clientId: String, val kind: String, val epoch: Long, val bytes: ByteArray, val targets: List<String>)
    private class RoomRows(
        var epoch: Long = 0, var nextSeq: Long = 0, val rows: MutableList<Row> = mutableListOf(),
        var closed: Boolean = false, val members: MutableSet<String> = mutableSetOf(), val acks: MutableMap<String, Long> = mutableMapOf(),
        /** 읽음 위치(#571 B, read.go): **actor** 별 하나(`max`). actor = 기기 ID 의 첫 `-` 앞(실제 릴레이는 mls_members.actor). */
        val reads: MutableMap<String, Long> = mutableMapOf(),
    )
    data class PushRow(val device: String, val token: ByteArray, val topic: String)
    /** 정책 체인의 기기 하나(DEVICES-V4 레코드의 공개 필드). */
    data class ChainDevice(val deviceId: String, val actor: String, val fingerprint: String, var status: String = "active", var roles: List<String> = emptyList())
    /** 우편함의 후보 행(devices.go `candidateView`). */
    data class CandidateRow(val deviceId: String, val actor: String, val signingKey: String, val fingerprint: String, val createdAt: Long, val expiresAt: Long)

    private val rooms = HashMap<String, RoomRows>()
    /** 로비 풀: 기기 → key package 바이트, 게시 순(가장 오래된 것부터 소비). */
    private val lobby = HashMap<String, ArrayDeque<ByteArray>>()
    var lobbyMax = 8
    val pushRows = mutableListOf<PushRow>()
    val trace = mutableListOf<String>()
    @Volatile var down = false
    /** 참이면 #571 B 이전 릴레이 흉내: `GET /events` 에 `read_seq` 없음, `POST /read` 는 봉투 없는 404(Go mux 기본 응답). */
    @Volatile var noReadRoute = false
    /** 참이면 #574 이전 릴레이 흉내: `/v2/me` 는 `{subject}` 만, 셀프서비스 라우트는 봉투 없는 404, `welcomes` 에 `from` 없음. */
    @Volatile var noSelfService = false

    // ---- 기기 정책 체인 대역(#574): 호출자 subject 는 늘 SUBJECT(토큰 없는 테스트) ----
    val chain = mutableListOf<ChainDevice>()
    val candidates = mutableListOf<CandidateRow>()
    var policyRevision = 1L
    /** 시계 대역(초) — 후보 TTL. */
    var now = 0L

    /** 운영자 CLI 대역(`-enroll-first`/`-add-device`): 활성 기기를 체인에 올린다. revision 이 하나 오른다. */
    @Synchronized fun enroll(deviceId: String, fingerprint: String, roles: List<String> = emptyList()) {
        chain += ChainDevice(deviceId, actorOf(deviceId), fingerprint, roles = roles)
        policyRevision += 1
    }
    @Synchronized fun chainDevice(deviceId: String): ChainDevice? = chain.firstOrNull { it.deviceId == deviceId }

    @Synchronized fun bumpEpoch(room: String) { rooms.getOrPut(room) { RoomRows() }.epoch += 1 }
    @Synchronized fun readSeq(room: String, actor: String): Long = rooms[room]?.reads?.get(actor) ?: 0L
    /** 같은 사람의 다른 기기(웹)가 읽은 것처럼 actor 값을 올린다. */
    @Synchronized fun setRead(room: String, actor: String, seq: Long) { rooms.getOrPut(room) { RoomRows() }.reads[actor] = seq }
    private fun actorOf(device: String) = device.substringBefore('-')
    @Synchronized fun pruneBefore(room: String, seq: Long) { rooms.getOrPut(room) { RoomRows() }.rows.removeAll { it.seq < seq } }
    @Synchronized fun rows(room: String): List<Row> = rooms[room]?.rows?.toList() ?: emptyList()
    @Synchronized fun lobbyLive(device: String): Int = lobby[device]?.size ?: 0
    /** steward 가 하는 일(`GET /v2/lobby/keypackages?device=&consumer=&room=`): 가장 오래된 로비 키 하나. */
    @Synchronized fun consumeLobby(device: String, consumer: String, room: String): ByteArray? {
        trace += "CONSUME lobby $device by $consumer for $room"
        return lobby[device]?.removeFirstOrNull()
    }

    @Synchronized
    override fun send(method: String, url: String, headers: List<HttpHeader>, body: ByteArray?): HttpResponse {
        if (down) throw RoomException.Host("connection refused (test)")
        check(headers.isEmpty()) { "no access token configured" }
        val path = url.removePrefix(base)
        val (p, query) = path.split('?', limit = 2).let { it[0] to it.getOrElse(1) { "" } }
        val bytes = body ?: ByteArray(0)
        if (p.startsWith("/v2/rooms/")) {
            val rest = p.removePrefix("/v2/rooms/")
            if (rest.endsWith("/events")) {
                val room = rest.removeSuffix("/events")
                return when (method) {
                    "GET" -> getEvents(room, query)
                    "POST" -> postEvent(room, bytes)
                    else -> error("unexpected method $method on events")
                }
            }
            if (rest.endsWith("/close")) { require(method == "POST"); return closeRoom(rest.removeSuffix("/close"), query) }
            if (rest.endsWith("/read")) { require(method == "POST"); return postRead(rest.removeSuffix("/read"), bytes) }
            if (rest.endsWith("/keypackages")) { require(method == "GET"); return consumeRoomRoute(rest.removeSuffix("/keypackages"), query) }
        }
        return when (method to p) {
            "GET" to "/v2/rooms" -> listRooms(query)
            "GET" to "/v2/me" -> getMe()
            "POST" to "/v2/devices/candidates" -> postCandidate(bytes)
            "GET" to "/v2/devices/candidates" -> listCandidates(query)
            "POST" to "/v2/devices/approvals" -> postApproval(bytes)
            "POST" to "/v2/devices/roles" -> postRoles(bytes)
            "POST" to "/v2/lobby/keypackages" -> postLobby(bytes)
            "GET" to "/v2/lobby/keypackages" -> consumeLobbyRoute(query)
            "DELETE" to "/v2/lobby/keypackages" -> deleteLobby(query)
            "GET" to "/v2/lobby/status" -> lobbyStatus(query)
            "GET" to "/v2/lobby/welcomes" -> lobbyWelcomes(query)
            "POST" to "/v2/push/devices" -> registerPush(bytes)
            "DELETE" to "/v2/push/devices" -> unregisterPush(query)
            else -> error("unexpected route $method $p")
        }
    }

    private fun respond(status: Int, json: String) = HttpResponse(status.toUShort(), json.toByteArray(Charsets.UTF_8))
    private fun noContent() = HttpResponse(204.toUShort(), ByteArray(0))
    private fun params(query: String) = query.split('&').filter { it.contains('=') }.associate { it.substringBefore('=') to it.substringAfter('=') }
    private fun b64(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)

    private fun getEvents(room: String, query: String): HttpResponse {
        val p = params(query)
        val device = p.getValue("device")
        val after = p.getValue("after").toLong()
        trace += "GET $device after=$after ack=${p["ack"] ?: "-"}"
        val state = rooms[room] ?: return respond(404, """{"error":"no_such_room"}""")
        if (state.closed) return respond(410, """{"error":"room_closed"}""")
        p["ack"]?.toLongOrNull()?.let { state.acks[device] = it }
        val events = state.rows
            .filter { it.seq > after && (it.kind != "welcome" || device in it.targets) }
            .joinToString(",") { r ->
                """{"seq":${r.seq},"device":"${r.device}","client_id":"${r.clientId}","kind":"${r.kind}","epoch":${r.epoch},""" +
                    """"bytes":"${b64(r.bytes)}","sha256":"","created_at":0}"""
            }
        val firstSeq = state.rows.firstOrNull()?.seq ?: 0
        val readSeq = if (noReadRoute) "" else ""","read_seq":${state.reads[actorOf(device)] ?: 0}"""
        return respond(200, """{"epoch":${state.epoch},"revision":0,"events":[$events],"first_seq":$firstSeq$readSeq}""")
    }

    /** `POST /v2/rooms/{room}/read {device, seq}`(#571 B, read.go): 404 · 410 · 403 `not_a_member` · 400 `bad_seq` 순서로 거르고 (방, actor) 값을 `max` 로 올린 뒤 답한다. */
    private fun postRead(room: String, body: ByteArray): HttpResponse {
        if (noReadRoute) return HttpResponse(404.toUShort(), "404 page not found\n".toByteArray(Charsets.UTF_8))
        val json = String(body, Charsets.UTF_8)
        check(reKey.findAll(json).count() == 2) { "strict body: exactly device and seq ($json)" }
        val device = reString.find(json)?.groupValues?.get(2) ?: error("device")
        val seq = reSeq.find(json)?.groupValues?.get(1)?.toLong() ?: error("seq")
        trace += "READ $device seq=$seq"
        val state = rooms[room] ?: return respond(404, """{"error":"no_such_room"}""")
        if (state.closed) return respond(410, """{"error":"room_closed"}""")
        if (device !in state.members) return respond(403, """{"error":"not_a_member"}""")
        if (seq < 0 || seq > state.nextSeq) return respond(400, """{"error":"bad_seq"}""")
        val actor = actorOf(device)
        val read = maxOf(state.reads[actor] ?: 0L, seq)
        state.reads[actor] = read
        return respond(200, """{"read_seq":$read}""")
    }

    private val reString = Regex(""""(device|client_id|kind|bytes|topic|apns_token)":"([^"]*)"""")
    private val reEpoch = Regex(""""epoch":(-?\d+)""")
    private val reSeq = Regex(""""seq":(-?\d+)""")
    private val reKey = Regex(""""[a-z_]+":""")
    private val reTargets = Regex(""""targets":\[([^\]]*)\]""")
    private val rePackage = Regex(""""ref":"([^"]*)","bytes":"([^"]*)"""")

    private fun postEvent(room: String, body: ByteArray): HttpResponse {
        val json = String(body, Charsets.UTF_8)
        val fields = reString.findAll(json).associate { it.groupValues[1] to it.groupValues[2] }
        val device = fields.getValue("device")
        val clientId = fields.getValue("client_id")
        val kind = fields.getValue("kind")
        val epoch = reEpoch.find(json)?.groupValues?.get(1)?.toLong() ?: 0
        val targets = reTargets.find(json)?.groupValues?.get(1)?.split(',')?.map { it.trim().trim('"') }?.filter { it.isNotEmpty() } ?: emptyList()
        trace += "POST $kind $clientId"
        val state = rooms.getOrPut(room) { RoomRows() }
        if (state.closed) return respond(410, """{"error":"room_closed"}""")
        state.rows.firstOrNull { it.device == device && it.clientId == clientId }?.let { existing ->
            return respond(200, """{"seq":${existing.seq},"epoch":${state.epoch},"revision":0,"duplicate":true}""")
        }
        if (kind != "welcome" && epoch != state.epoch) return respond(409, """{"error":"cas_mismatch"}""")
        state.members += device
        state.members += targets
        state.nextSeq += 1
        val seq = state.nextSeq
        state.rows += Row(seq, device, clientId, kind, state.epoch, Base64.getDecoder().decode(fields.getValue("bytes")), targets)
        if (kind == "commit") state.epoch += 1
        return respond(200, """{"seq":$seq,"epoch":${state.epoch},"revision":0,"duplicate":false}""")
    }

    private fun closeRoom(room: String, query: String): HttpResponse {
        val device = params(query).getValue("device")
        trace += "CLOSE $room by $device"
        val state = rooms[room] ?: return respond(404, """{"error":"no_such_room"}""")
        if (device !in state.members) return respond(403, """{"error":"not_a_member"}""")
        state.closed = true
        return respond(200, """{"room":"$room","closed":true}""")
    }

    private fun postLobby(body: ByteArray): HttpResponse {
        val json = String(body, Charsets.UTF_8)
        val device = reString.findAll(json).associate { it.groupValues[1] to it.groupValues[2] }.getValue("device")
        val packages = rePackage.findAll(json).map { Base64.getDecoder().decode(it.groupValues[2]) }.toList()
        trace += "POST lobby $device n=${packages.size}"
        val pool = lobby.getOrPut(device) { ArrayDeque() }
        if (pool.size + packages.size > lobbyMax) return respond(409, """{"error":"key_package_limit","live":${pool.size},"max":$lobbyMax}""")
        pool.addAll(packages)
        return respond(201, """{"stored":${packages.size},"duplicates":0,"live":${pool.size}}""")
    }

    private fun consumeLobbyRoute(query: String): HttpResponse {
        val p = params(query)
        val bytes = consumeLobby(p.getValue("device"), p.getValue("consumer"), p.getValue("room"))
            ?: return respond(404, """{"error":"no_live_key_package"}""")
        return respond(200, """{"ref":"${sha256Hex(bytes)}","bytes":"${b64(bytes)}","expires_at":0}""")
    }

    /** 방 풀 소비(`GET /v2/rooms/{room}/keypackages`): 대역에는 방 풀이 없다 — 늘 404(→ `MlsRoom.invite` 가 로비로 넘어간다, #380). */
    private fun consumeRoomRoute(room: String, query: String): HttpResponse {
        val p = params(query)
        trace += "CONSUME room ${p.getValue("device")} by ${p.getValue("consumer")} for $room"
        return respond(404, """{"error":"no_live_key_package"}""")
    }

    // ---- #574 기기 셀프서비스(devices.go · me.go 의 규칙; 서명은 길이만 검사) ----

    private fun sha256Hex(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun unhex(text: String): ByteArray? {
        if (text.length % 2 != 0 || !text.all { it in '0'..'9' || it in 'a'..'f' }) return null
        return text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }
    private fun bare404() = HttpResponse(404.toUShort(), "404 page not found\n".toByteArray(Charsets.UTF_8))
    private val reAnyString = Regex(""""([a-z_]+)":"([^"]*)"""")
    private val reBaseRevision = Regex(""""base_revision":(\d+)""")
    private val reRoles = Regex(""""roles":\[([^\]]*)\]""")
    private fun stringFields(json: String) = reAnyString.findAll(json).associate { it.groupValues[1] to it.groupValues[2] }
    private fun strict(json: String, keys: Set<String>) {
        val got = reKey.findAll(json).map { it.value.trim('"', ':') }.toSet()
        check(got == keys) { "strict body: expected $keys, got $got ($json)" }
    }
    /** devicepolicy.VerifyApproval/VerifyRoles 의 서명자 규칙: 활성이고, registrar 이거나 그 actor 에 활성 registrar 가 없다. */
    private fun approverAllowed(approver: String, actor: String): String? {
        val a = chain.firstOrNull { it.deviceId == approver } ?: return "approver $approver is not on the chain"
        if (a.status != "active") return "approver $approver is not active"
        if (a.actor != actor) return "approver $approver is another actor"
        val hasRegistrar = chain.any { it.actor == actor && it.status == "active" && "registrar" in it.roles }
        if (hasRegistrar && "registrar" !in a.roles) return "approver $approver is not a registrar"
        return null
    }

    private fun getMe(): HttpResponse {
        trace += "ME"
        if (noSelfService) return respond(200, """{"subject":"$SUBJECT"}""")
        val devices = chain.joinToString(",") { d ->
            """{"device_id":"${d.deviceId}","actor":"${d.actor}","fingerprint":"${d.fingerprint}","status":"${d.status}","acceptance":"trusted-device-fingerprint","roles":[${d.roles.joinToString(",") { "\"$it\"" }}]}"""
        }
        return respond(200, """{"subject":"$SUBJECT","policy_revision":$policyRevision,"devices":[$devices]}""")
    }

    /** devices.go `handlePostCandidate`: 엄격 본문(subject 없음) · 지문 = sha256(공개키) · 체인에 있는 ID 는 409 · 활성 기기 없으면 403 · 재게시는 갱신. */
    private fun postCandidate(body: ByteArray): HttpResponse {
        if (noSelfService) return bare404()
        val json = String(body, Charsets.UTF_8)
        strict(json, setOf("device_id", "actor", "signing_key", "fingerprint"))
        val f = stringFields(json)
        val deviceId = f.getValue("device_id")
        trace += "CANDIDATE $deviceId"
        val key = unhex(f.getValue("signing_key"))?.takeIf { it.size == 32 } ?: return respond(400, """{"error":"bad_candidate","detail":"signing_key"}""")
        val computed = sha256Hex(key)
        if (f.getValue("fingerprint").isNotEmpty() && f.getValue("fingerprint") != computed) return respond(400, """{"error":"bad_candidate","detail":"fingerprint does not match signing_key"}""")
        if (chain.any { it.deviceId == deviceId }) return respond(409, """{"error":"device_exists","detail":"ids are never reused; start again with a new device id"}""")
        if (chain.none { it.status == "active" }) return respond(403, """{"error":"first_device_out_of_band"}""")
        candidates.removeAll { it.expiresAt <= now || it.deviceId == deviceId }
        val expiresAt = now + CANDIDATE_TTL_SECONDS
        candidates += CandidateRow(deviceId, f.getValue("actor"), f.getValue("signing_key"), computed, now, expiresAt)
        return respond(201, """{"device_id":"$deviceId","fingerprint":"$computed","policy_revision":$policyRevision,"expires_at":$expiresAt}""")
    }

    /** `GET /v2/devices/candidates?device=`: bindDevice(활성·호출자 소유) 뒤 우편함. */
    private fun listCandidates(query: String): HttpResponse {
        if (noSelfService) return bare404()
        val device = params(query).getValue("device")
        trace += "CANDIDATES $device"
        if (chain.none { it.deviceId == device && it.status == "active" }) return respond(403, """{"error":"device_not_allowed"}""")
        candidates.removeAll { it.expiresAt <= now }
        val rows = candidates.joinToString(",") { c ->
            """{"device_id":"${c.deviceId}","actor":"${c.actor}","subject":"$SUBJECT","signing_key":"${c.signingKey}","fingerprint":"${c.fingerprint}","created_at":${c.createdAt},"expires_at":${c.expiresAt}}"""
        }
        return respond(200, """{"policy_revision":$policyRevision,"candidates":[$rows]}""")
    }

    /** `POST /v2/devices/approvals` = AddDeviceEvidence(엄격): subject 바인딩 → revision CAS → 서명자 규칙 → 체인 commit → 후보 삭제. */
    private fun postApproval(body: ByteArray): HttpResponse {
        if (noSelfService) return bare404()
        val json = String(body, Charsets.UTF_8)
        strict(json, setOf("device_id", "actor", "subject", "signing_key", "base_revision", "signature", "fingerprint", "approved_by"))
        val f = stringFields(json)
        val (deviceId, actor, approver) = Triple(f.getValue("device_id"), f.getValue("actor"), f.getValue("approved_by"))
        trace += "APPROVE $deviceId by $approver"
        if (f.getValue("subject") != SUBJECT) return respond(403, """{"error":"subject_mismatch"}""")
        val base = reBaseRevision.find(json)?.groupValues?.get(1)?.toLong() ?: -1L
        if (base != policyRevision) return respond(409, """{"error":"stale_revision","detail":"base_revision $base != $policyRevision","revision":$policyRevision}""")
        if (f.getValue("signature").length != 128 || unhex(f.getValue("signature")) == null) return respond(403, """{"error":"approval_rejected","detail":"signature"}""")
        val key = unhex(f.getValue("signing_key"))?.takeIf { it.size == 32 }
        if (key == null || sha256Hex(key) != f.getValue("fingerprint")) return respond(400, """{"error":"bad_candidate","detail":"fingerprint"}""")
        if (chain.any { it.deviceId == deviceId }) return respond(400, """{"error":"bad_candidate","detail":"duplicate id"}""")
        approverAllowed(approver, actor)?.let { return respond(403, """{"error":"approval_rejected","detail":"$it"}""") }
        chain += ChainDevice(deviceId, actor, f.getValue("fingerprint"))
        policyRevision += 1
        candidates.removeAll { it.deviceId == deviceId }
        return respond(201, """{"device_id":"$deviceId","approved_by":"$approver","revision":$policyRevision}""")
    }

    /** `POST /v2/devices/roles` = RolesEvidence(엄격): 대상 호출자 소유 → CAS → 서명자 규칙 → 마지막 registrar 보호 → commit. */
    private fun postRoles(body: ByteArray): HttpResponse {
        if (noSelfService) return bare404()
        val json = String(body, Charsets.UTF_8)
        strict(json, setOf("device_id", "actor", "roles", "base_revision", "signature", "approved_by"))
        val f = stringFields(json)
        val (deviceId, actor, approver) = Triple(f.getValue("device_id"), f.getValue("actor"), f.getValue("approved_by"))
        val roles = reRoles.find(json)?.groupValues?.get(1)?.split(',')?.map { it.trim().trim('"') }?.filter { it.isNotEmpty() } ?: emptyList()
        trace += "ROLES $deviceId $roles by $approver"
        val target = chain.firstOrNull { it.deviceId == deviceId } ?: return respond(403, """{"error":"device_subject_mismatch"}""")
        val base = reBaseRevision.find(json)?.groupValues?.get(1)?.toLong() ?: -1L
        if (base != policyRevision) return respond(409, """{"error":"stale_revision","detail":"base_revision $base != $policyRevision","revision":$policyRevision}""")
        if (target.status != "active" || target.actor != actor) return respond(403, """{"error":"approval_rejected","detail":"target is not an active device of that actor"}""")
        approverAllowed(approver, actor)?.let { return respond(403, """{"error":"approval_rejected","detail":"$it"}""") }
        val registrars = chain.count { it.actor == actor && it.status == "active" && "registrar" in it.roles }
        if ("registrar" in target.roles && "registrar" !in roles && registrars <= 1) return respond(403, """{"error":"approval_rejected","detail":"last registrar of the actor cannot release the role"}""")
        target.roles = roles
        policyRevision += 1
        return respond(201, """{"device_id":"$deviceId","roles":[${roles.joinToString(",") { "\"$it\"" }}],"approved_by":"$approver","revision":$policyRevision}""")
    }

    private fun deleteLobby(query: String): HttpResponse {
        val device = params(query).getValue("device")
        trace += "DELETE lobby $device"
        val deleted = lobby[device]?.size ?: 0
        lobby[device]?.clear()
        return respond(200, """{"device":"$device","deleted":$deleted}""")
    }

    private fun lobbyStatus(query: String): HttpResponse {
        val device = params(query).getValue("device")
        trace += "STATUS lobby $device"
        return respond(200, """{"device":"$device","live":${lobbyLive(device)},"max":$lobbyMax,"ttl_seconds":2592000}""")
    }

    private fun lobbyWelcomes(query: String): HttpResponse {
        val device = params(query).getValue("device")
        trace += "WELCOMES $device"
        val welcomes = rooms.entries.sortedBy { it.key }.mapNotNull { (name, state) ->
            if (state.closed) return@mapNotNull null
            val acked = state.acks[device] ?: 0
            state.rows.firstOrNull { it.kind == "welcome" && device in it.targets && it.seq > acked }
                ?.let { w ->
                    // #574: 보낸 기기 `from` — 옛 릴레이 흉내에서는 없다.
                    val from = if (noSelfService) "" else ",\"from\":\"${w.device}\""
                    """{"room":"$name","seq":${w.seq},"epoch":${w.epoch},"created_at":0$from}"""
                }
        }
        return respond(200, """{"welcomes":[${welcomes.joinToString(",")}]}""")
    }

    private fun listRooms(query: String): HttpResponse {
        val device = params(query).getValue("device")
        trace += "ROOMS $device"
        val listing = rooms.entries.sortedBy { it.key }.joinToString(",") { (name, state) ->
            """{"room":"$name","epoch":${state.epoch},"revision":0,"member":${device in state.members},"keypackages_outstanding":0,"closed":${state.closed}}"""
        }
        return respond(200, """{"rooms":[$listing]}""")
    }

    private fun registerPush(body: ByteArray): HttpResponse {
        val fields = reString.findAll(String(body, Charsets.UTF_8)).associate { it.groupValues[1] to it.groupValues[2] }
        val device = fields.getValue("device")
        val token = Base64.getDecoder().decode(fields["apns_token"] ?: "")
        val topic = fields.getValue("topic")
        if (token.isEmpty()) return respond(400, """{"error":"bad_apns_token"}""")
        trace += "PUSH register $device $topic"
        pushRows.removeAll { it.device == device && it.token.contentEquals(token) }
        pushRows += PushRow(device, token, topic)
        return noContent()
    }

    private fun unregisterPush(query: String): HttpResponse {
        val device = params(query).getValue("device")
        trace += "PUSH unregister $device"
        pushRows.removeAll { it.device == device }
        return noContent()
    }

    companion object {
        /** 호출자 subject 대역(#574): 토큰이 없는 테스트라 모든 요청이 이 사람이다(me.go `c.subject`). */
        const val SUBJECT = "person-owner"
        /** 후보 TTL(devices.go `candidateTTL`), 초. */
        const val CANDIDATE_TTL_SECONDS = 600L
    }
}
