// 테스트 전용 in-memory 릴레이(`ios-ffi/tests/room_host.rs` 의 Relay 와 같은 규칙): v2 events 라우트만 — GET 페이지(Welcome 은 대상에게만),
// POST(client_id dedup · epoch 불일치 409 cas_mismatch · commit 은 epoch+1). MLS 검증 없음, 순서 매기기만. JSON 은 코어가 만든 EventPost 의
// 고정 필드만 정규식으로 읽는다(테스트 외 사용 금지).
package com.seoyoon_family.hande.host

import com.seoyoon_family.hande.mls.HttpHeader
import com.seoyoon_family.hande.mls.HttpResponse
import com.seoyoon_family.hande.mls.HttpTransport
import com.seoyoon_family.hande.mls.RoomException
import java.util.Base64

class InMemoryRelay(private val base: String) : HttpTransport {
    data class Row(val seq: Long, val device: String, val clientId: String, val kind: String, val epoch: Long, val bytes: ByteArray, val targets: List<String>)
    private class RoomRows(var epoch: Long = 0, var nextSeq: Long = 0, val rows: MutableList<Row> = mutableListOf())

    private val rooms = HashMap<String, RoomRows>()
    val trace = mutableListOf<String>()
    @Volatile var down = false

    @Synchronized fun bumpEpoch(room: String) { rooms.getOrPut(room) { RoomRows() }.epoch += 1 }
    @Synchronized fun pruneBefore(room: String, seq: Long) { rooms.getOrPut(room) { RoomRows() }.rows.removeAll { it.seq < seq } }
    @Synchronized fun rows(room: String): List<Row> = rooms[room]?.rows?.toList() ?: emptyList()

    @Synchronized
    override fun send(method: String, url: String, headers: List<HttpHeader>, body: ByteArray?): HttpResponse {
        if (down) throw RoomException.Host("connection refused (test)")
        check(headers.isEmpty()) { "no access token configured" }
        val path = url.removePrefix(base)
        val (p, query) = path.split('?', limit = 2).let { it[0] to it.getOrElse(1) { "" } }
        val room = p.removePrefix("/v2/rooms/").removeSuffix("/events")
        require(p.startsWith("/v2/rooms/") && p.endsWith("/events")) { "unexpected route $p" }
        return when (method) {
            "GET" -> get(room, query)
            "POST" -> post(room, body ?: ByteArray(0))
            else -> error("unexpected method $method")
        }
    }

    private fun respond(status: Int, json: String) = HttpResponse(status.toUShort(), json.toByteArray(Charsets.UTF_8))

    private fun get(room: String, query: String): HttpResponse {
        val params = query.split('&').filter { it.contains('=') }.associate { it.substringBefore('=') to it.substringAfter('=') }
        val device = params.getValue("device")
        val after = params.getValue("after").toLong()
        trace += "GET $device after=$after ack=${params["ack"] ?: "-"}"
        val state = rooms[room] ?: return respond(404, """{"error":"no_such_room"}""")
        val events = state.rows
            .filter { it.seq > after && (it.kind != "welcome" || device in it.targets) }
            .joinToString(",") { r ->
                """{"seq":${r.seq},"device":"${r.device}","client_id":"${r.clientId}","kind":"${r.kind}","epoch":${r.epoch},""" +
                    """"bytes":"${Base64.getEncoder().encodeToString(r.bytes)}","sha256":"","created_at":0}"""
            }
        val firstSeq = state.rows.firstOrNull()?.seq ?: 0
        return respond(200, """{"epoch":${state.epoch},"revision":0,"events":[$events],"first_seq":$firstSeq}""")
    }

    private val reString = Regex(""""(device|client_id|kind|bytes)":"([^"]*)"""")
    private val reEpoch = Regex(""""epoch":(-?\d+)""")
    private val reTargets = Regex(""""targets":\[([^\]]*)\]""")

    private fun post(room: String, body: ByteArray): HttpResponse {
        val json = String(body, Charsets.UTF_8)
        val fields = reString.findAll(json).associate { it.groupValues[1] to it.groupValues[2] }
        val device = fields.getValue("device")
        val clientId = fields.getValue("client_id")
        val kind = fields.getValue("kind")
        val epoch = reEpoch.find(json)?.groupValues?.get(1)?.toLong() ?: 0
        val targets = reTargets.find(json)?.groupValues?.get(1)?.split(',')?.map { it.trim().trim('"') }?.filter { it.isNotEmpty() } ?: emptyList()
        trace += "POST $kind $clientId"
        val state = rooms.getOrPut(room) { RoomRows() }
        state.rows.firstOrNull { it.device == device && it.clientId == clientId }?.let { existing ->
            return respond(200, """{"seq":${existing.seq},"epoch":${state.epoch},"revision":0,"duplicate":true}""")
        }
        if (kind != "welcome" && epoch != state.epoch) return respond(409, """{"error":"cas_mismatch"}""")
        state.nextSeq += 1
        val seq = state.nextSeq
        state.rows += Row(seq, device, clientId, kind, state.epoch, Base64.getDecoder().decode(fields.getValue("bytes")), targets)
        if (kind == "commit") state.epoch += 1
        return respond(200, """{"seq":$seq,"epoch":${state.epoch},"revision":0,"duplicate":false}""")
    }
}
