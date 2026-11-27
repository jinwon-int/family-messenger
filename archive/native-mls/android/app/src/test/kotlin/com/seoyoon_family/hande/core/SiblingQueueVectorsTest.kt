// 형제 초대 대기열·빠진 방 재탐색 공용 벡터(#366 3h-a, #616) — host-core `sibling_queue`(ios-ffi)·웹 `self-service.js` 와 같은 파일
// `archive/native-mls/tests/fixtures/sibling-queue-vectors.json` 을 이 앱의 [SelfService]·[SiblingRescan] 으로 돌린다. 앱 경로(Kotlin
// 변환 + JNA 경계)가 코어와 같은 판정인지, 그리고 SharedPreferences 텍스트 형식이 그대로인지 본다.
// android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`). JSON 읽개는 AgentChoicesTest 의 [MiniJson].
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.mls.MlsMe
import com.seoyoon_family.hande.mls.MlsMeDevice
import com.seoyoon_family.hande.mls.siblingRescanConstants
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

class SiblingQueueVectorsTest {
    private val fixture: Map<*, *> by lazy {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val f = File(dir, "archive/native-mls/tests/fixtures/sibling-queue-vectors.json")
            if (f.isFile) return@lazy MiniJson(f.readText(Charsets.UTF_8)).parse() as Map<*, *>
            dir = dir.parentFile
        }
        fail("sibling-queue-vectors.json not found above ${File(".").absolutePath}")
    }

    private fun cases(key: String): List<Map<*, *>> {
        val list = (fixture[key] as List<*>).map { it as Map<*, *> }
        assertTrue(list.isNotEmpty(), key)
        return list
    }

    private fun num(v: Any?): Long = (v as Number).toLong()
    private fun optNum(v: Any?): Long? = (v as Number?)?.toLong()

    @Suppress("UNCHECKED_CAST")
    private fun strings(v: Any?): List<String> = v as List<String>

    private fun entry(v: Any?): SelfService.SiblingInvite {
        val m = v as Map<*, *>
        return SelfService.SiblingInvite(
            target = m["target"] as String, rooms = strings(m["rooms"]), since = num(m["since"]),
            progress = optNum(m["progress"]), recheckAt = optNum(m["recheck_at"]), origin = m["origin"] as String?,
        )
    }

    private fun entryMap(e: SelfService.SiblingInvite?): Map<String, Any?>? = e?.let {
        mapOf("target" to it.target, "rooms" to it.rooms, "since" to it.since, "progress" to it.progress, "recheck_at" to it.recheckAt, "origin" to it.origin)
    }

    private fun queue(v: Any?): List<SelfService.SiblingInvite> = (v as List<*>).map { entry(it) }

    private fun state(v: Any?): SiblingRescan.State {
        val m = v as Map<*, *>
        val pending = LinkedHashMap<String, Long>()
        for (p in m["pending"] as List<*>) { val pm = p as Map<*, *>; pending[pm["key"] as String] = num(pm["seen"]) }
        return SiblingRescan.State(optNum(m["last"]), pending)
    }

    private fun stateMap(s: SiblingRescan.State): Map<String, Any?> =
        mapOf("last" to s.last, "pending" to s.pending.map { (k, v) -> mapOf("key" to k, "seen" to v) })

    private fun me(c: Map<*, *>): MlsMe? {
        val key = c["me"] as String? ?: return null
        val m = (fixture["mes"] as Map<*, *>)[key] as Map<*, *>
        return MlsMe(
            subject = m["subject"] as String,
            policyRevision = optNum(m["policy_revision"])?.toULong(),
            devices = (m["devices"] as List<*>).map {
                val d = it as Map<*, *>
                MlsMeDevice(
                    deviceId = d["device_id"] as String, actor = d["actor"] as String, fingerprint = d["fingerprint"] as String,
                    status = d["status"] as String, acceptance = d["acceptance"] as String, roles = strings(d["roles"]),
                )
            },
        )
    }

    @Test fun constantsMatchCore() {
        val c = fixture["constants"] as Map<*, *>
        val core = siblingRescanConstants()
        assertEquals(num(c["rescan_interval_ms"]), SiblingRescan.INTERVAL_MS)
        assertEquals(num(c["rescan_deferral_ms"]), SiblingRescan.DEFERRAL_MS)
        assertEquals(c["rescan_origin"], SiblingRescan.ORIGIN)
        assertEquals(num(c["sibling_invite_ttl_ms"]), SelfService.SIBLING_INVITE_TTL_MS)
        assertEquals(SiblingRescan.INTERVAL_MS, core.intervalMs)
        assertEquals(SiblingRescan.DEFERRAL_MS, core.deferralMs)
        assertEquals(SiblingRescan.ORIGIN, core.origin)
    }

    @Test fun queueRules() {
        for (c in cases("enqueue")) {
            val got = SelfService.enqueueSiblingInvites(queue(c["queue"]), c["target"] as String, strings(c["rooms"]), num(c["now"]), c["origin"] as String?)
            assertEquals(c["expect"], got.map { entryMap(it) }, "${c["name"]}")
        }
        for (c in cases("split")) {
            val (live, expired) = SelfService.splitSiblingQueue(queue(c["queue"]), num(c["now"]), num(c["ttl"]))
            assertEquals(c["expect"], mapOf("live" to live.map { it.target }, "expired" to expired.map { it.target }), "${c["name"]}")
        }
        for (c in cases("budget")) {
            val want = optNum(c["expect"])?.toInt() ?: Int.MAX_VALUE
            assertEquals(want, SelfService.budget(optNum(c["live"])?.toInt()), "${c["name"]}")
        }
    }

    @Test fun queueTextFormat() {
        for (c in cases("queue_text_decode")) {
            assertEquals(c["expect"], SelfService.decodeSiblingQueue(c["text"] as String?).map { entryMap(it) }, "${c["name"]}")
        }
        for (c in cases("queue_text_encode")) {
            val q = queue(c["queue"])
            assertEquals(c["expect"], SelfService.encodeSiblingQueue(q), "${c["name"]}")
            assertEquals(q, SelfService.decodeSiblingQueue(SelfService.encodeSiblingQueue(q)), "round trip ${c["name"]}")
        }
    }

    @Test fun rescanRules() {
        for (c in cases("rescan_siblings")) assertEquals(c["expect"], SiblingRescan.siblings(me(c), c["device"] as String), "${c["name"]}")
        for (c in cases("rescan_due")) assertEquals(c["expect"], SiblingRescan.due(state(c["state"]), num(c["now"])), "${c["name"]}")
        for (c in cases("rescan_turn")) {
            val rooms = (c["rooms"] as List<*>).map {
                val r = it as Map<*, *>
                SelfService.RoomView(
                    room = r["room"] as String, joined = r["joined"] as Boolean, halted = r["halted"] as Boolean,
                    pending = r["pending"] as Boolean, roster = (r["roster"] as List<*>?)?.map { m -> m as String }, synced = r["synced"] as Boolean,
                )
            }
            val excluded = LinkedHashMap<String, List<String>?>()
            for ((k, v) in c["excluded"] as Map<*, *>) excluded[k as String] = (v as List<*>?)?.map { it as String }
            val t = SiblingRescan.turn(rooms, c["device"] as String, strings(c["siblings"]), excluded, state(c["state"]), num(c["now"]))
            val got = mapOf(
                "ready" to t.ready,
                "enqueue" to t.enqueue.map { (target, rs) -> mapOf("target" to target, "rooms" to rs) },
                "state" to stateMap(t.state),
            )
            assertEquals(c["expect"], got, "${c["name"]}")
        }
    }

    @Test fun rescanTextFormat() {
        for (c in cases("rescan_state_text_decode")) assertEquals(c["expect"], stateMap(SiblingRescan.decodeState(c["text"] as String?)), "${c["name"]}")
        for (c in cases("rescan_state_text_encode")) {
            val s = state(c["state"])
            assertEquals(c["expect"], SiblingRescan.encodeState(s), "${c["name"]}")
            assertEquals(s, SiblingRescan.decodeState(SiblingRescan.encodeState(s)), "round trip ${c["name"]}")
        }
    }
}
