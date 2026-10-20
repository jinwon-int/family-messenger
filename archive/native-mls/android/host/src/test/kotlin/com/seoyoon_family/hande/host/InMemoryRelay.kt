// 테스트 전용 in-memory 릴레이(`ios-ffi/tests/support/mod.rs` 의 Relay 와 같은 규칙): v2 events 라우트 — GET 페이지(Welcome 은 대상에게만),
// POST(client_id dedup · epoch 불일치 409 cas_mismatch · commit 은 epoch+1) — 에 3c 의 기기 수준 라우트(로비 key package · 방 목록 · 방 닫기 ·
// 푸시 등록)를 더했다. MLS 검증 없음, 순서 매기기만. JSON 은 코어가 만든 고정 필드만 정규식으로 읽는다(테스트 외 사용 금지).
package com.seoyoon_family.hande.host

import com.seoyoon_family.hande.mls.HttpHeader
import com.seoyoon_family.hande.mls.HttpResponse
import com.seoyoon_family.hande.mls.HttpTransport
import com.seoyoon_family.hande.mls.RoomException
import java.util.Base64

class InMemoryRelay(private val base: String) : HttpTransport {
    data class Row(val seq: Long, val device: String, val clientId: String, val kind: String, val epoch: Long, val bytes: ByteArray, val targets: List<String>)
    private class RoomRows(
        var epoch: Long = 0, var nextSeq: Long = 0, val rows: MutableList<Row> = mutableListOf(),
        var closed: Boolean = false, val members: MutableSet<String> = mutableSetOf(), val acks: MutableMap<String, Long> = mutableMapOf(),
    )
    data class PushRow(val device: String, val token: ByteArray, val topic: String)

    private val rooms = HashMap<String, RoomRows>()
    /** 로비 풀: 기기 → key package 바이트, 게시 순(가장 오래된 것부터 소비). */
    private val lobby = HashMap<String, ArrayDeque<ByteArray>>()
    var lobbyMax = 8
    val pushRows = mutableListOf<PushRow>()
    val trace = mutableListOf<String>()
    @Volatile var down = false

    @Synchronized fun bumpEpoch(room: String) { rooms.getOrPut(room) { RoomRows() }.epoch += 1 }
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
        }
        return when (method to p) {
            "GET" to "/v2/rooms" -> listRooms(query)
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
        return respond(200, """{"epoch":${state.epoch},"revision":0,"events":[$events],"first_seq":$firstSeq}""")
    }

    private val reString = Regex(""""(device|client_id|kind|bytes|topic|apns_token)":"([^"]*)"""")
    private val reEpoch = Regex(""""epoch":(-?\d+)""")
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
        return respond(200, """{"ref":"","bytes":"${b64(bytes)}","expires_at":0}""")
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
                ?.let { """{"room":"$name","seq":${it.seq},"epoch":${it.epoch},"created_at":0}""" }
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
}
