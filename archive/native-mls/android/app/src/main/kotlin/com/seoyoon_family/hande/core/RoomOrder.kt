// 대화 목록 고정 순서(#715 room-order v1 · #549 순서 편집) — 순수 규칙. 웹 `web/hande/room-order.js`(orderRooms/moveRoom)·
// iOS FamilyMLSCore `RoomOrder`(apply/step/moveToTop/canStep)와 같은 뜻이고, 릴레이 계약(`GET/PUT /v2/me/room-order`)의 본문 읽기·쓰기를 함께 둔다.
//   · 표시(규칙 3): 저장된 순서의 방을 먼저, 거기 없는 방은 기본 순서(허브가 넘긴 순서 그대로)로 뒤에. 없어진 방 ID 는 무시. 최근 활동순으로 움직이지 않는다.
//   · 편집: ▲▼ 는 화면 순서에서 한 칸, 「맨 위로 고정」은 맨 앞으로. 지금 목록에 없지만 저장돼 있던 방 ID(다른 기기에만 있는 방)는 버리지 않고 뒤에 둔다(웹 moveRoom).
//   · 저장 상한 64개 · 항목은 릴레이 `validIdentifier`(영문·숫자·`-`·`_` 1~64자) — 어긋난 ID 는 올리지 않는다(400 bad_identifier 를 만들지 않게).
// android.* 없음 — JVM 단위 테스트(`RoomOrderTest`).
package com.seoyoon_family.hande.core

object RoomOrder {
    /** 릴레이가 받는 `rooms` 최대 개수(계약 v1). 로컬 저장도 같은 상한 — 넘치면 앞쪽(화면 위쪽)을 남긴다. */
    const val LIMIT = 64
    const val PATH = "/v2/me/room-order"
    private val IDENTIFIER = Regex("^[A-Za-z0-9_-]{1,64}$")

    fun validId(id: String): Boolean = IDENTIFIER.matches(id)

    /** 중복·형식이 틀린 ID 를 빼고 상한까지(앞쪽 우선). */
    fun normalize(ids: List<String>): List<String> {
        val seen = HashSet<String>()
        val out = ArrayList<String>()
        for (id in ids) {
            if (!validId(id) || !seen.add(id)) continue
            out += id
            if (out.size >= LIMIT) break
        }
        return out
    }

    /** 규칙 3: 저장된 순서를 먼저, 거기 없는 방은 `rooms` 의 순서 그대로 뒤에. 없어진 방 ID·중복은 무시. 입력은 바꾸지 않는다. */
    fun <T> apply(rooms: List<T>, saved: List<String>, id: (T) -> String): List<T> {
        if (saved.isEmpty()) return rooms
        val byId = LinkedHashMap<String, T>()
        for (r in rooms) byId.putIfAbsent(id(r), r)
        val seen = HashSet<String>()
        val out = ArrayList<T>(rooms.size)
        for (s in saved) {
            if (s in seen) continue
            val r = byId[s] ?: continue
            out += r
            seen += s
        }
        for (r in rooms) if (seen.add(id(r))) out += r
        return out
    }

    /** #549 ▲(−1)/▼(+1): 화면 순서(`ids`)에서 `room` 을 한 칸 옮긴 새 순서. 끝·없는 방·0 이동이면 null(바꿀 것 없음). */
    fun step(ids: List<String>, room: String, delta: Int): List<String>? {
        if (delta == 0) return null
        val from = ids.indexOf(room)
        if (from < 0) return null
        val to = from + delta
        if (to !in ids.indices) return null
        val next = ids.toMutableList()
        next[from] = next[to]
        next[to] = room
        return next
    }

    /** #549 「맨 위로 고정」: `room` 을 맨 앞으로. 이미 맨 앞이거나 없는 방이면 null. */
    fun moveToTop(ids: List<String>, room: String): List<String>? {
        val from = ids.indexOf(room)
        if (from <= 0) return null
        val next = ids.toMutableList()
        next.removeAt(from)
        next.add(0, room)
        return next
    }

    /** ▲▼ 를 눌러도 되는가 — 끝에서는 비활성(웹·iOS 와 같다). */
    fun canStep(ids: List<String>, room: String, delta: Int): Boolean = step(ids, room, delta) != null

    /** 화면 순서로 옮긴 결과(`visible`) 뒤에 지금 목록에 없는 저장 ID 를 붙인 새 저장 순서(웹 moveRoom 의 hidden) — 정규화·상한 적용. */
    fun withHidden(visible: List<String>, saved: List<String>): List<String> {
        val shown = visible.toHashSet()
        return normalize(visible + saved.filter { it !in shown })
    }

    // ---- 로컬 저장 형식(Settings `room_order`) = JSON 문자열 배열 ----

    fun encode(ids: List<String>): String = ids.joinToString(",", "[", "]") { jsonString(it) }

    /** 저장 문자열 → 방 ID 목록. 형식이 틀리면 빈 목록(= 기본 순서). */
    fun decode(raw: String?): List<String> {
        if (raw.isNullOrBlank()) return emptyList()
        val doc = try { StrictJson(raw).parseDocument() } catch (_: StrictJson.Malformed) { return emptyList() }
        return normalize((doc as? List<*>)?.filterIsInstance<String>() ?: return emptyList())
    }

    // ---- 릴레이 계약 v1 ----

    /** 서버가 아는 순서. `revision == 0` = 저장된 적 없음. `updatedAt` 은 Unix 초. */
    data class Snapshot(val rooms: List<String>, val revision: Long, val updatedAt: Long)

    /** `<relay>/v2/me/room-order?device=<id>` — http(s) 릴레이가 아니면 null. */
    fun getUrl(relayUrl: String, device: String): String? =
        base(relayUrl)?.let { "$it$PATH?device=" + java.net.URLEncoder.encode(device, "UTF-8") }

    fun putUrl(relayUrl: String): String? = base(relayUrl)?.let { it + PATH }

    private fun base(relayUrl: String): String? {
        val b = relayUrl.trim().trimEnd('/')
        return if (b.startsWith("https://") || b.startsWith("http://")) b else null
    }

    /** `PUT` 본문 `{"device","rooms","base_revision"}`. */
    fun putBody(device: String, rooms: List<String>, baseRevision: Long): String =
        "{\"device\":${jsonString(device)},\"rooms\":${encode(rooms)},\"base_revision\":$baseRevision}"

    /**
     * 200 본문·409 본문(`{"error":"revision_conflict","rooms","revision","updated_at"}`) → 스냅숏. `rooms` 가 배열이 아니거나 `revision` 이
     * 음수가 아닌 정수가 아니면 null. 항목 중 형식이 틀린 ID·중복은 버린다(표시는 어차피 내 방만). `updated_at` 이 없으면 0.
     */
    fun parseSnapshot(json: String): Snapshot? {
        if (json.length > MAX_BODY_CHARS) return null
        val doc = (try { StrictJson(json).parseDocument() } catch (_: StrictJson.Malformed) { null }) as? Map<*, *> ?: return null
        val rooms = doc["rooms"] as? List<*> ?: return null
        val revision = wholeNumber(doc["revision"]) ?: return null
        val updatedAt = wholeNumber(doc["updated_at"]) ?: 0L
        return Snapshot(normalize(rooms.filterIsInstance<String>()), revision, updatedAt)
    }

    private fun wholeNumber(v: Any?): Long? {
        val d = (v as? StrictJson.Num)?.value ?: return null
        if (d < 0 || d != Math.floor(d) || d > 9.0e15) return null
        return d.toLong()
    }

    /** 응답 본문 상한 — 64개 × 64자 + 여유. */
    private const val MAX_BODY_CHARS = 16 * 1024

    private fun jsonString(s: String): String {
        val b = StringBuilder(s.length + 2).append('"')
        for (c in s) {
            when {
                c == '"' -> b.append("\\\"")
                c == '\\' -> b.append("\\\\")
                c < ' ' -> b.append("\\u%04x".format(c.code))
                else -> b.append(c)
            }
        }
        return b.append('"').toString()
    }
}
