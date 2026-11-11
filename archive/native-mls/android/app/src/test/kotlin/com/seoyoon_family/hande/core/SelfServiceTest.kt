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

    // ---- #616: 잔량 예산 · 진행 기준 TTL · 재탐색 (iOS SelfServiceTests · 웹 tests/self-service.test.mjs 와 같은 경우들) ----

    @Test fun siblingTtlIsADayFromTheLastProgress() {
        assertEquals(24 * 60 * 60_000L, SelfService.SIBLING_INVITE_TTL_MS)
        val ttl = SelfService.SIBLING_INVITE_TTL_MS
        val q = listOf(
            SelfService.SiblingInvite("moved", listOf("a"), since = 0L, progress = 10_000L),
            SelfService.SiblingInvite("still", listOf("b"), since = 0L),
        )
        val (live, expired) = SelfService.splitSiblingQueue(q, 5_000L + ttl)
        assertEquals(listOf("moved"), live.map { it.target }, "progress restarts the TTL")
        assertEquals(listOf("still"), expired.map { it.target })
    }

    @Test fun siblingInviteRoomsSkipPendingAndRosterMembers() {
        val rooms = listOf(
            SelfService.RoomView("family", true, false),
            SelfService.RoomView("busy", true, false, pending = true),
            SelfService.RoomView("has", true, false, roster = listOf("owner-pc", "owner-android")),
            SelfService.RoomView("lacks", true, false, roster = listOf("owner-pc")),
        )
        assertEquals(listOf("family", "lacks"), SelfService.siblingInviteRooms(rooms, "owner-android"))
        assertEquals(listOf("family", "has", "lacks"), SelfService.siblingInviteRooms(rooms), "no target: roster not consulted")
    }

    @Test fun siblingQueueKeepsProgressFieldsAndReadsTheOldFormat() {
        val q = listOf(
            SelfService.SiblingInvite("owner-android", listOf("family"), 1_000L),
            SelfService.SiblingInvite("owner-pc", listOf("kids", "work"), 2_000L, progress = 3_000L, recheckAt = 4_000L, origin = SiblingRescan.ORIGIN),
            SelfService.SiblingInvite("owner-tab", listOf("family"), 5_000L, recheckAt = 6_000L),
        )
        val text = SelfService.encodeSiblingQueue(q)
        assertEquals("owner-android|1000|family\nowner-pc|2000|kids,work|3000|4000|rescan\nowner-tab|5000|family||6000|", text, "old 3-field lines stay as they were")
        assertEquals(q, SelfService.decodeSiblingQueue(text))
        assertEquals(emptyList<SelfService.SiblingInvite>(), SelfService.decodeSiblingQueue("a-b|1|r|x||\na-b|1|r|||bad origin\na-b|1|r|1|2"), "broken extended lines are dropped")
        // 재탐색 출처: 같은 target 이 있으면 원래 출처를 지킨다.
        val merged = SelfService.enqueueSiblingInvites(q, "owner-android", listOf("kids"), 9_000L, origin = SiblingRescan.ORIGIN)
        assertNull(merged.first().origin)
        assertEquals(listOf("family", "kids"), merged.first().rooms)
        assertEquals(SiblingRescan.ORIGIN, SelfService.enqueueSiblingInvites(emptyList(), "owner-new", listOf("a"), 1L, origin = SiblingRescan.ORIGIN).single().origin)
    }

    @Test fun budgetFollowsTheSiblingsLiveLobbyKeys() {
        assertEquals(Int.MAX_VALUE, SelfService.budget(null), "unknown (old relay / error): unlimited as before")
        assertEquals(0, SelfService.budget(0))
        assertEquals(0, SelfService.budget(-3))
        assertEquals(5, SelfService.budget(5))
    }

    private fun views(vararg names: String) = names.associateWith { SelfService.RoomView(it, true, false) }

    @Test fun inviteTurnSpendsOnlyTheLiveKeysAndRecordsProgress() {
        val e = SelfService.SiblingInvite("owner-android", listOf("r1", "r2", "r3", "r4"), since = 0L)
        val tried = ArrayList<String>()
        val v = views("r1", "r2", "r3", "r4")
        val t = SelfService.siblingInviteTurn(e, 100L, lobbyLive = { 2 }, roomView = { v[it] }) { tried += it; SelfService.InviteOutcome.Invited }
        assertEquals(listOf("r1", "r2"), tried, "17 rooms with 8 keys must not burn the rest on no-key failures")
        assertEquals(listOf("r1", "r2"), t.invited)
        assertEquals(e.copy(rooms = listOf("r3", "r4"), progress = 100L, recheckAt = null), t.entry)
    }

    @Test fun inviteTurnWithNoKeysWaitsAMinuteWithoutTrying() {
        val e = SelfService.SiblingInvite("owner-android", listOf("r1", "r2"), since = 0L, progress = 50L)
        val v = views("r1", "r2")
        val t = SelfService.siblingInviteTurn(e, 1_000L, lobbyLive = { 0 }, roomView = { v[it] }) { error("must not invite with zero keys") }
        assertEquals(e.copy(recheckAt = 1_000L + SelfService.SIBLING_LOBBY_RECHECK_MS), t.entry, "progress kept, recheck in 60 s")
        // recheckAt 전에는 잔량도 묻지 않는다.
        val waiting = t.entry!!
        val again = SelfService.siblingInviteTurn(waiting, 30_000L, lobbyLive = { error("must not ask before recheckAt") }, roomView = { v[it] }) { error("no") }
        assertEquals(waiting, again.entry)
        // 시각이 되면 다시 묻고, 키가 생겼으면 초대한다.
        val later = SelfService.siblingInviteTurn(waiting, 61_000L, lobbyLive = { 8 }, roomView = { v[it] }) { SelfService.InviteOutcome.Invited }
        assertEquals(listOf("r1", "r2"), later.invited)
        assertNull(later.entry, "nothing left")
    }

    @Test fun inviteTurnNoKeyStopsTheTurnAndOtherOutcomesSort() {
        val e = SelfService.SiblingInvite("owner-android", listOf("gone", "member", "busy", "dead", "fail", "retry", "nokey", "after"), since = 0L)
        val v = mapOf(
            "member" to SelfService.RoomView("member", true, false, roster = listOf("owner-android")),
            "busy" to SelfService.RoomView("busy", true, false, pending = true),
            "dead" to SelfService.RoomView("dead", true, true),
        ) + views("fail", "retry", "nokey", "after")
        val tried = ArrayList<String>()
        val t = SelfService.siblingInviteTurn(e, 7L, lobbyLive = { null }, roomView = { v[it] }) { room ->
            tried += room
            when (room) {
                "fail" -> SelfService.InviteOutcome.Failed("policy")
                "retry" -> SelfService.InviteOutcome.Retry
                else -> SelfService.InviteOutcome.NoKey
            }
        }
        assertEquals(listOf("fail", "retry", "nokey"), tried, "no-key: the count was stale, stop this turn")
        assertEquals(listOf("fail" to "policy"), t.failed)
        assertTrue(t.invited.isEmpty())
        assertEquals(listOf("busy", "retry", "nokey", "after"), t.entry?.rooms, "gone/member/dead finish; pending waits")
        assertEquals(7L + SelfService.SIBLING_LOBBY_RECHECK_MS, t.entry?.recheckAt, "starved without progress")
        assertNull(t.entry?.progress)
    }

    @Test fun parseLobbyStatusReadsLiveAndExcludedRooms() {
        assertEquals(SelfService.LobbyPeek(3, listOf("kids")), SelfService.parseLobbyStatus("""{"device":"owner-pc","live":3,"max":8,"ttl_seconds":604800,"excluded_rooms":["kids","kids","bad room"]}"""))
        assertEquals(SelfService.LobbyPeek(0, emptyList()), SelfService.parseLobbyStatus("""{"device":"owner-pc","live":0,"max":8,"ttl_seconds":1,"excluded_rooms":[]}"""))
        assertEquals(SelfService.LobbyPeek(4, null), SelfService.parseLobbyStatus("""{"device":"owner-pc","live":4,"max":8,"ttl_seconds":1}"""), "old relay: no field")
        assertEquals(SelfService.LobbyPeek(4, null), SelfService.parseLobbyStatus("""{"live":4,"excluded_rooms":null}"""))
        assertNull(SelfService.parseLobbyStatus("""{"live":-1}"""))
        assertNull(SelfService.parseLobbyStatus("""{"live":1.5}"""))
        assertNull(SelfService.parseLobbyStatus("""{"live":2,"excluded_rooms":"kids"}"""))
        assertNull(SelfService.parseLobbyStatus("""{"max":8}"""))
        assertNull(SelfService.parseLobbyStatus("not json"))
    }

    private fun rosterFrame(vararg ids: String): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        fun u32(v: Int) { out.write(v and 0xff); out.write((v shr 8) and 0xff); out.write((v shr 16) and 0xff); out.write((v shr 24) and 0xff) }
        u32(ids.size)
        for (id in ids) { val b = id.toByteArray(); u32(b.size); out.write(b); out.write(ByteArray(32) { 7 }) }
        return out.toByteArray()
    }

    @Test fun parseRosterFrameMatchesTheEngineFraming() {
        assertEquals(listOf("owner-pc", "bot-1"), SelfService.parseRosterFrame(rosterFrame("owner-pc", "bot-1")))
        assertEquals(emptyList<String>(), SelfService.parseRosterFrame(rosterFrame()))
        val ok = rosterFrame("owner-pc")
        assertNull(SelfService.parseRosterFrame(ok.copyOf(ok.size - 1)), "truncated key")
        assertNull(SelfService.parseRosterFrame(ok + byteArrayOf(0)), "trailing byte")
        assertNull(SelfService.parseRosterFrame(byteArrayOf(1, 0)), "truncated count")
    }

    @Test fun rescanSiblingsAreMyOtherActiveDevices() {
        val m = me(dev("owner-pc"), dev("owner-iphone"), dev("owner-old", status = "revoked"), dev("kid-tab"), dev("owner-android"))
        assertEquals(listOf("owner-android", "owner-iphone"), SiblingRescan.siblings(m, "owner-pc"))
        assertEquals(emptyList<String>(), SiblingRescan.siblings(m, "owner-unknown"))
        assertEquals(emptyList<String>(), SiblingRescan.siblings(me(dev("owner-pc", status = "revoked"), dev("owner-iphone")), "owner-pc"))
        assertEquals(emptyList<String>(), SiblingRescan.siblings(null, "owner-pc"))
    }

    @Test fun rescanIsDueEverySixHoursOrWhenADeferralMatures() {
        val h6 = SiblingRescan.INTERVAL_MS
        assertTrue(SiblingRescan.due(SiblingRescan.State(), 0L), "never ran")
        assertFalse(SiblingRescan.due(SiblingRescan.State(last = 1_000L), 1_000L + h6 - 1))
        assertTrue(SiblingRescan.due(SiblingRescan.State(last = 1_000L), 1_000L + h6))
        val deferred = SiblingRescan.State(last = 1_000L, pending = mapOf("owner-iphone|family" to 2_000L))
        assertFalse(SiblingRescan.due(deferred, 2_000L + SiblingRescan.DEFERRAL_MS - 1))
        assertTrue(SiblingRescan.due(deferred, 2_000L + SiblingRescan.DEFERRAL_MS))
    }

    @Test fun rescanStateRoundTrips() {
        val s = SiblingRescan.State(last = 5L, pending = linkedMapOf("owner-iphone|family" to 7L, "owner-iphone|kids" to 9L))
        val text = SiblingRescan.encodeState(s)
        assertEquals("5\nowner-iphone|family|7\nowner-iphone|kids|9", text)
        assertEquals(s, SiblingRescan.decodeState(text))
        assertEquals(SiblingRescan.State(), SiblingRescan.decodeState(SiblingRescan.encodeState(SiblingRescan.State())))
        assertEquals(SiblingRescan.State(), SiblingRescan.decodeState("garbage"))
        assertEquals(SiblingRescan.State(last = 1L), SiblingRescan.decodeState("1\nbad line\nx|y|notanumber"))
    }

    @Test fun rescanTurnSkipsExcludedRoomsAndOldRelaysAndPicksOneInviter() {
        val rooms = listOf(
            SelfService.RoomView("family", true, false, roster = listOf("owner-android", "bot-1")),           // iphone 빠짐, 나만 있음 → 내가 리더
            SelfService.RoomView("kids", true, false, roster = listOf("owner-android")),                       // iphone 을 일부러 내보냄
            SelfService.RoomView("work", true, false, roster = listOf("owner-android", "owner-aaa")),          // 더 작은 ID 가 있음 → 미룸
            SelfService.RoomView("both", true, false, roster = listOf("owner-android", "owner-iphone")),       // 이미 있음
            SelfService.RoomView("halted", true, true, roster = listOf("owner-android")),
        )
        val siblings = listOf("owner-aaa", "owner-iphone", "owner-tab")
        val excluded = mapOf("owner-aaa" to emptyList(), "owner-iphone" to listOf("kids"), "owner-tab" to null)   // tab = 옛 릴레이 응답
        val t = SiblingRescan.turn(rooms, "owner-android", siblings, excluded, SiblingRescan.State(), now = 1_000L)
        assertTrue(t.ready)
        // aaa: work 에는 이미 있다 → family·kids·both 가 대상이고, 세 방 모두 내 기기 중 ID 최소가 나(android) → 바로.
        // iphone: kids 는 내보낸 방 → 건너뜀, both 에는 있음, family 는 내가 리더 → 바로, work 는 aaa 가 리더 → 미룸. tab: 옛 릴레이 → 건너뜀.
        assertEquals(listOf("owner-aaa" to listOf("family", "kids", "both"), "owner-iphone" to listOf("family")), t.enqueue)
        assertEquals(SiblingRescan.State(last = 1_000L, pending = mapOf("owner-iphone|work" to 1_000L)), t.state, "work: owner-aaa leads, I wait 30 min")
        // 30분 뒤에도 빠져 있으면 내가 넣는다.
        val later = SiblingRescan.turn(rooms, "owner-android", listOf("owner-iphone"), mapOf("owner-iphone" to listOf("kids")), t.state, now = 1_000L + SiblingRescan.DEFERRAL_MS)
        assertEquals(listOf("owner-iphone" to listOf("family", "work")), later.enqueue)
        assertTrue(later.state.pending.isEmpty())
    }

    @Test fun rescanTurnWaitsUntilEveryJoinedRoomIsSynced() {
        val rooms = listOf(SelfService.RoomView("family", true, false, roster = emptyList(), synced = false), SelfService.RoomView("halted", true, true, synced = true))
        val state = SiblingRescan.State(last = 1L)
        val t = SiblingRescan.turn(rooms, "owner-android", listOf("owner-iphone"), mapOf("owner-iphone" to emptyList()), state, now = 9L)
        assertFalse(t.ready)
        assertEquals(state, t.state, "state untouched — next tick")
        assertTrue(t.enqueue.isEmpty())
    }
}
