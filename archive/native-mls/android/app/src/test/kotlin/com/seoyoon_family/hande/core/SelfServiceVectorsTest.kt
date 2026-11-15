// 셀프서비스 공용 벡터(#366 3g) — host-core `self_service`(봇·ios-ffi)·웹 `self-service.js` 와 같은 파일
// `archive/native-mls/tests/fixtures/self-service-vectors.json` 을 이 앱의 [SelfService] 로 돌린다. [SelfService] 의 판정은 코어를
// 부르므로, 이 테스트는 JNA 경계와 Kotlin 쪽 변환(행 정렬·RoomView·EnrollMode)까지 포함한 앱 경로가 코어 판정 그대로인지 본다.
// android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`, 호스트 cdylib 은 `<ffiOut>/host`). JSON 읽개는 AgentChoicesTest 의 [MiniJson].
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.mls.MlsCandidate
import com.seoyoon_family.hande.mls.MlsMe
import com.seoyoon_family.hande.mls.MlsMeDevice
import com.seoyoon_family.hande.mls.selfServiceConstants
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

class SelfServiceVectorsTest {
    private val fixture: Map<*, *> by lazy {
        var dir: File? = File(".").absoluteFile
        while (dir != null) {
            val f = File(dir, "archive/native-mls/tests/fixtures/self-service-vectors.json")
            if (f.isFile) return@lazy MiniJson(f.readText(Charsets.UTF_8)).parse() as Map<*, *>
            dir = dir.parentFile
        }
        fail("self-service-vectors.json not found above ${File(".").absolutePath}")
    }

    private fun cases(key: String): List<Map<*, *>> {
        val list = (fixture[key] as List<*>).map { it as Map<*, *> }
        assertTrue(list.isNotEmpty(), key)
        return list
    }

    private fun num(v: Any?): Long = (v as Number).toLong()

    @Suppress("UNCHECKED_CAST")
    private fun strings(v: Any?): List<String> = v as List<String>

    private fun device(d: Map<*, *>) = MlsMeDevice(
        deviceId = d["device_id"] as String, actor = d["actor"] as String, fingerprint = d["fingerprint"] as String,
        status = d["status"] as String, acceptance = d["acceptance"] as String, roles = strings(d["roles"]),
    )

    private fun me(c: Map<*, *>): MlsMe? {
        val key = c["me"] as String? ?: return null
        val m = (fixture["mes"] as Map<*, *>)[key] as Map<*, *>
        return MlsMe(
            subject = m["subject"] as String,
            policyRevision = (m["policy_revision"] as Number?)?.toLong()?.toULong(),
            devices = (m["devices"] as List<*>).map { device(it as Map<*, *>) },
        )
    }

    @Test fun constantsMatchCore() {
        val c = fixture["constants"] as Map<*, *>
        val core = selfServiceConstants()
        assertEquals(c["role_registrar"], SelfService.ROLE_REGISTRAR)
        assertEquals(c["status_active"], SelfService.STATUS_ACTIVE)
        assertEquals(num(c["sibling_invite_ttl_ms"]), SelfService.SIBLING_INVITE_TTL_MS)
        assertEquals(num(c["sibling_lobby_recheck_ms"]), SelfService.SIBLING_LOBBY_RECHECK_MS)
        assertEquals(num(c["candidate_repost_margin_ms"]), SelfService.CANDIDATE_REPOST_MARGIN_MS)
        assertEquals(num(c["candidate_ttl_seconds"]), SelfService.CANDIDATE_TTL_SECONDS)
        assertEquals(SelfService.ROLE_REGISTRAR, core.roleRegistrar)
        assertEquals(SelfService.STATUS_ACTIVE, core.statusActive)
        assertEquals(SelfService.SIBLING_INVITE_TTL_MS.toULong(), core.siblingInviteTtlMs)
        assertEquals(SelfService.SIBLING_LOBBY_RECHECK_MS.toULong(), core.siblingLobbyRecheckMs)
        assertEquals(SelfService.CANDIDATE_REPOST_MARGIN_MS.toULong(), core.candidateRepostMarginMs)
        assertEquals(SelfService.CANDIDATE_TTL_SECONDS.toULong(), core.candidateTtlSeconds)
    }

    @Test fun actorHasRegistrarAndCanApprove() {
        for (c in cases("actor_has_registrar")) assertEquals(c["expect"], SelfService.actorHasRegistrar(me(c), c["actor"] as String), "${c["name"]}")
        for (c in cases("can_approve")) assertEquals(c["expect"], SelfService.canApprove(me(c), c["device"] as String), "${c["name"]}")
    }

    @Test fun isSibling() {
        for (c in cases("is_sibling")) {
            assertEquals(c["expect"], SelfService.isSibling(c["from"] as String?, me(c), c["actor"] as String?, c["device"] as String), "${c["name"]}")
        }
    }

    @Test fun candidatesFor() {
        for (c in cases("candidates_for")) {
            val list = (c["candidates"] as List<*>).map {
                it as Map<*, *>
                MlsCandidate(
                    deviceId = it["device_id"] as String, actor = it["actor"] as String, subject = it["subject"] as String,
                    signingKey = it["signing_key"] as String, fingerprint = it["fingerprint"] as String,
                    createdAt = num(it["created_at"]), expiresAt = num(it["expires_at"]),
                )
            }
            assertEquals(strings(c["expect"]), SelfService.candidatesFor(list, c["actor"] as String).map { it.deviceId }, "${c["name"]}")
        }
    }

    @Test fun nextRoles() {
        for (c in cases("next_roles")) assertEquals(strings(c["expect"]), SelfService.nextRoles(strings(c["roles"]), c["grant"] as Boolean), "$c")
    }

    @Test fun rolesActionsInChainOrderAfterUndoingThisDeviceFirst() {
        for (c in cases("roles_actions")) {
            val device = c["device"] as String
            val v = SelfService.rolesActions(me(c), device)
            val e = c["expect"] as Map<*, *>
            assertEquals(e["can_sign"], v.canSign, "${c["name"]}")
            assertEquals(e["actor"], v.actor, "${c["name"]}")
            // 앱은 이 기기를 먼저 보인다(화면 정렬) — 벡터의 체인 순서와 비교하려고 체인 순서로 되돌린다.
            val order = me(c)?.devices.orEmpty().map { it.deviceId }
            assertEquals(v.devices.firstOrNull()?.isSelf ?: false, v.devices.any { it.isSelf }, "this device first: ${c["name"]}")
            val rows = v.devices.sortedBy { order.indexOf(it.deviceId) }.map {
                mapOf("device_id" to it.deviceId, "registrar" to it.registrar, "is_self" to it.isSelf, "grant" to it.grant, "release" to it.release, "last_registrar" to it.lastRegistrar)
            }
            assertEquals(e["devices"], rows, "${c["name"]}")
        }
    }

    @Test fun siblingInviteRooms() {
        for (c in cases("sibling_invite_rooms")) {
            val rooms = (c["rooms"] as List<*>).map {
                it as Map<*, *>
                @Suppress("UNCHECKED_CAST")
                SelfService.RoomView(it["room"] as String, it["joined"] as Boolean, it["halted"] as Boolean, pending = it["pending"] as Boolean, roster = it["roster"] as List<String>?)
            }
            assertEquals(strings(c["expect"]), SelfService.siblingInviteRooms(rooms, c["target"] as String?), "${c["name"]}")
        }
    }

    @Test fun enrollMode() {
        val names = mapOf(SelfService.EnrollMode.SIBLING to "sibling", SelfService.EnrollMode.ID_TAKEN to "id-taken", SelfService.EnrollMode.OPERATOR to "operator")
        for (c in cases("enroll_mode")) assertEquals(c["expect"], names[SelfService.enrollModeFrom(num(c["status"]).toInt(), c["code"] as String)], "$c")
        assertEquals(SelfService.EnrollMode.OPERATOR, SelfService.enrollModeFrom(-1, ""), "out-of-range status")
        assertEquals(SelfService.EnrollMode.OPERATOR, SelfService.enrollModeFrom(70_000, "device_exists"), "out-of-range status")
    }
}
