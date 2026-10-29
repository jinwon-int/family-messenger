// 기기 셀프서비스 판정 고정(#574 PR 4) — 웹 `tests/self-service.test.mjs` 와 같은 경우들. android.* 없이 JVM 에서 돈다
// (uniffi 레코드는 평범한 data class 라 네이티브 라이브러리를 건드리지 않는다).
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.mls.MlsCandidate
import com.seoyoon_family.hande.mls.MlsMe
import com.seoyoon_family.hande.mls.MlsMeDevice
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SelfServiceTest {
    private val hex64 = "ab".repeat(32)
    private fun dev(id: String, status: String = "active", roles: List<String> = emptyList(), fingerprint: String = hex64) =
        MlsMeDevice(deviceId = id, actor = id.substringBefore('-'), fingerprint = fingerprint, status = status, acceptance = "trusted-device-fingerprint", roles = roles)
    private fun me(vararg devices: MlsMeDevice, revision: ULong? = 5uL) = MlsMe(subject = "person-owner", policyRevision = revision, devices = devices.toList())
    private fun cand(id: String, actor: String = id.substringBefore('-'), key: String = hex64, fp: String = hex64) =
        MlsCandidate(deviceId = id, actor = actor, subject = "person-owner", signingKey = key, fingerprint = fp, createdAt = 0, expiresAt = 600)

    @Test fun recordAndRegistrar() {
        val m = me(dev("owner-iphone", roles = listOf("registrar")), dev("owner-pc", status = "revoked"))
        assertEquals("owner-iphone", SelfService.recordOf(m, "owner-iphone")?.deviceId)
        assertNull(SelfService.recordOf(m, "owner-android"))
        assertNull(SelfService.recordOf(null, "owner-iphone"))
        assertTrue(SelfService.actorHasRegistrar(m, "owner"))
        assertFalse(SelfService.actorHasRegistrar(m, "kid"))
        assertFalse(SelfService.actorHasRegistrar(me(dev("owner-iphone", status = "revoked", roles = listOf("registrar"))), "owner"), "a revoked registrar does not count")
    }

    @Test fun canApproveFollowsTheServerRules() {
        // registrar 가 있는 actor: registrar 만.
        val withRegistrar = me(dev("owner-iphone", roles = listOf("registrar")), dev("owner-pc"))
        assertTrue(SelfService.canApprove(withRegistrar, "owner-iphone"))
        assertFalse(SelfService.canApprove(withRegistrar, "owner-pc"))
        // registrar 가 없는 actor(#574 이전 체인): 활성 기기면 누구나.
        val without = me(dev("owner-iphone"), dev("owner-pc"))
        assertTrue(SelfService.canApprove(without, "owner-pc"))
        // 폐기·미등록·/v2/me 없음은 불가.
        assertFalse(SelfService.canApprove(me(dev("owner-pc", status = "revoked")), "owner-pc"))
        assertFalse(SelfService.canApprove(without, "owner-android"))
        assertFalse(SelfService.canApprove(null, "owner-pc"))
    }

    @Test fun siblingIsAnActiveSameActorDeviceOtherThanMe() {
        val m = me(dev("owner-iphone"), dev("owner-old", status = "revoked"), dev("kid-tablet"))
        assertTrue(SelfService.isSibling("owner-iphone", m, "owner", "owner-android"))
        assertFalse(SelfService.isSibling("owner-android", m, "owner", "owner-android"), "myself")
        assertFalse(SelfService.isSibling("owner-old", m, "owner", "owner-android"), "revoked")
        assertFalse(SelfService.isSibling("kid-tablet", m, "owner", "owner-android"), "another actor")
        assertFalse(SelfService.isSibling("bot-steward", m, "owner", "owner-android"), "not on my chain")
        assertFalse(SelfService.isSibling("", m, "owner", "owner-android"))
        assertFalse(SelfService.isSibling(null, m, "owner", "owner-android"))
        assertFalse(SelfService.isSibling("owner-iphone", null, "owner", "owner-android"), "old relay: no /v2/me")
        assertFalse(SelfService.isSibling("owner-iphone", m, null, "owner-android"))
    }

    @Test fun candidatesForKeepsWellFormedRowsOfMyActor() {
        val rows = listOf(cand("owner-android"), cand("kid-phone"), cand("owner-bad", key = "zz"), cand("owner-short", fp = "ab"))
        assertEquals(listOf("owner-android"), SelfService.candidatesFor(rows, "owner").map { it.deviceId })
        assertEquals(listOf("kid-phone"), SelfService.candidatesFor(rows, "kid").map { it.deviceId })
        assertTrue(SelfService.candidatesFor(emptyList(), "owner").isEmpty())
    }

    @Test fun nextRolesIsACompleteSortedList() {
        assertEquals(listOf("registrar"), SelfService.nextRoles(emptyList(), true))
        assertEquals(listOf("registrar"), SelfService.nextRoles(listOf("registrar", "registrar"), true))
        assertEquals(emptyList<String>(), SelfService.nextRoles(listOf("registrar"), false))
        assertEquals(listOf("other", "registrar"), SelfService.nextRoles(listOf("registrar", "other"), true))
    }

    @Test fun rolesActionsGrantReleaseAndLastRegistrar() {
        val m = me(dev("owner-pc"), dev("owner-iphone", roles = listOf("registrar")), dev("owner-old", status = "revoked"), dev("kid-tablet"))
        val v = SelfService.rolesActions(m, "owner-iphone")
        assertTrue(v.canSign)
        assertEquals("owner", v.actor)
        assertEquals(listOf("owner-iphone", "owner-pc", "owner-old", "kid-tablet"), v.devices.map { it.deviceId }, "this device first, then the chain order")
        val self = v.devices[0]
        assertTrue(self.isSelf && self.registrar && !self.grant && !self.release && self.lastRegistrar, "$self")
        val pc = v.devices[1]
        assertTrue(pc.grant && !pc.release && !pc.lastRegistrar, "$pc")
        val old = v.devices[2]
        assertFalse(old.grant || old.release || old.lastRegistrar, "revoked: nothing")
        val kid = v.devices[3]
        assertFalse(kid.grant || kid.release, "another actor: nothing")

        // 두 registrar 면 서로 해제할 수 있다.
        val two = me(dev("owner-pc", roles = listOf("registrar")), dev("owner-iphone", roles = listOf("registrar")))
        val w = SelfService.rolesActions(two, "owner-iphone")
        assertTrue(w.devices.all { it.release && !it.lastRegistrar }, "$w")
        // registrar 가 아닌 기기는 아무것도 못 한다.
        val none = SelfService.rolesActions(m, "owner-pc")
        assertFalse(none.canSign)
        assertTrue(none.devices.none { it.grant || it.release || it.lastRegistrar })
        // /v2/me 없음.
        assertEquals(SelfService.RolesView(false, null, emptyList()), SelfService.rolesActions(null, "owner-pc"))
    }

    @Test fun siblingInviteRoomsAreJoinedAndNotHalted() {
        val rooms = listOf(SelfService.RoomView("family", true, false), SelfService.RoomView("pending", false, false), SelfService.RoomView("dead", true, true))
        assertEquals(listOf("family"), SelfService.siblingInviteRooms(rooms))
    }

    @Test fun enrollModeFromStatus() {
        assertEquals(SelfService.EnrollMode.SIBLING, SelfService.enrollModeFrom(201, ""))
        assertEquals(SelfService.EnrollMode.ID_TAKEN, SelfService.enrollModeFrom(409, "device_exists"))
        assertEquals(SelfService.EnrollMode.OPERATOR, SelfService.enrollModeFrom(409, "stale_revision"))
        assertEquals(SelfService.EnrollMode.OPERATOR, SelfService.enrollModeFrom(403, "first_device_out_of_band"))
        assertEquals(SelfService.EnrollMode.OPERATOR, SelfService.enrollModeFrom(404, ""))
        assertEquals(SelfService.EnrollMode.OPERATOR, SelfService.enrollModeFrom(500, "device_policy_unavailable"))
    }

    @Test fun repostFiveMinutesBeforeExpiry() {
        assertEquals(600_000L - 300_000L, SelfService.nextPostAt(600_000L, 10L))
        assertEquals(10L + 300_000L, SelfService.nextPostAt(null, 10L))
        assertEquals(10L + 300_000L, SelfService.nextPostAt(0L, 10L))
    }

    @Test fun groupedFingerprint() {
        val fp = "0123456789abcdef".repeat(4)
        assertEquals("0123 4567 89ab cdef\n0123 4567 89ab cdef\n0123 4567 89ab cdef\n0123 4567 89ab cdef", SelfService.groupedFingerprint(fp))
        assertEquals("abc", SelfService.groupedFingerprint("abc"))
    }

    @Test fun siblingQueueRoundTripsAndMerges() {
        val q0 = SelfService.decodeSiblingQueue(null)
        assertTrue(q0.isEmpty())
        val q1 = SelfService.enqueueSiblingInvites(q0, "owner-android", listOf("family", "family", "kids"), 1_000L)
        assertEquals(listOf(SelfService.SiblingInvite("owner-android", listOf("family", "kids"), 1_000L)), q1)
        val q2 = SelfService.enqueueSiblingInvites(q1, "owner-android", listOf("kids", "work"), 9_000L)
        assertEquals(listOf(SelfService.SiblingInvite("owner-android", listOf("family", "kids", "work"), 1_000L)), q2, "same target: rooms merge, time kept")
        assertEquals(q2, SelfService.enqueueSiblingInvites(q2, "owner-x", emptyList(), 9_000L), "no rooms: unchanged")
        val q3 = SelfService.enqueueSiblingInvites(q2, "owner-tablet", listOf("family"), 2_000L)
        val text = SelfService.encodeSiblingQueue(q3)
        assertEquals("owner-android|1000|family,kids,work\nowner-tablet|2000|family", text)
        assertEquals(q3, SelfService.decodeSiblingQueue(text))
        assertEquals("", SelfService.encodeSiblingQueue(emptyList()))
        // 깨진 줄은 버린다(식별자 규칙·숫자).
        assertEquals(listOf(SelfService.SiblingInvite("a-b", listOf("r1"), 5L)), SelfService.decodeSiblingQueue("bad line\nx|notanumber|r\na-b|5|r1,bad room\n"))
    }

    @Test fun dismissalsPersistByDeviceIdAndExpireWithTheCandidateTtl() {
        val ttl = SelfService.CANDIDATE_TTL_SECONDS
        val d0 = SelfService.decodeDismissals(null)
        assertTrue(d0.isEmpty())
        // 무시: 후보의 created_at(릴레이 초) 로 적는다; 재게시로 created_at 이 바뀌어도 ID 로 숨긴다.
        val d1 = SelfService.dismiss(d0, "owner-android", createdAt = 1_000L, nowSec = 1_010L)
        assertEquals(listOf(SelfService.Dismissal("owner-android", 1_000L)), d1)
        assertTrue(SelfService.isDismissed(d1, "owner-android", nowSec = 1_010L))
        assertTrue(SelfService.isDismissed(d1, "owner-android", nowSec = 1_000L + ttl - 1), "hidden until the row would expire")
        assertFalse(SelfService.isDismissed(d1, "owner-android", nowSec = 1_000L + ttl), "expires with the candidate TTL")
        assertFalse(SelfService.isDismissed(d1, "owner-tablet", nowSec = 1_010L), "another id")
        // 같은 ID 를 다시 무시하면 항목이 하나로 갱신되고, 만료된 항목은 걷힌다.
        val d2 = SelfService.dismiss(d1 + SelfService.Dismissal("owner-old", 1L), "owner-android", createdAt = 5_000L, nowSec = 5_000L)
        assertEquals(listOf(SelfService.Dismissal("owner-android", 5_000L)), d2)
        // created_at 을 모르면(0) 지금부터 TTL.
        val d3 = SelfService.dismiss(emptyList(), "owner-pc", createdAt = 0L, nowSec = 7_000L)
        assertEquals(listOf(SelfService.Dismissal("owner-pc", 7_000L)), d3)
        // 저장 왕복 · 깨진 줄은 버린다.
        val text = SelfService.encodeDismissals(d2 + d3)
        assertEquals("owner-android|5000\nowner-pc|7000", text)
        assertEquals(d2 + d3, SelfService.decodeDismissals(text))
        assertEquals("", SelfService.encodeDismissals(emptyList()))
        assertEquals(listOf(SelfService.Dismissal("a-b", 5L)), SelfService.decodeDismissals("bad line\nx|notanumber\nbad id|5\na-b|5\n"))
        assertEquals(emptyList<SelfService.Dismissal>(), SelfService.pruneDismissals(d1, nowSec = 1_000L + ttl))
    }

    @Test fun siblingQueueSplitsByTtl() {
        val q = listOf(SelfService.SiblingInvite("fresh", listOf("a"), 100_000L), SelfService.SiblingInvite("stale", listOf("b"), 0L))
        val (live, expired) = SelfService.splitSiblingQueue(q, 100_000L + SelfService.SIBLING_INVITE_TTL_MS)
        assertEquals(listOf("fresh"), live.map { it.target })
        assertEquals(listOf("stale"), expired.map { it.target })
        val (all, none) = SelfService.splitSiblingQueue(q, 1_000L, ttl = 10_000L)
        assertEquals(2, all.size); assertTrue(none.isEmpty())
    }
}
