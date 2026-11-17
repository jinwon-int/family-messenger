// `StoredFirst` 고정(#766 B): 저장된 신원·방이 있으면 `probe` 결과 없이 `Starting` 을 벗어나 저장된 목록·대화를 보이고(`Phase.Stored`),
// 세션이 필요한 동작은 `Ready` 까지 막힌다. 처음 실행·방 없음은 전과 같이 `probe` 를 기다린다.
// 허브(`DeviceHub.boot`·`probe`)가 화면 상태를 바꿀 때 쓰는 바로 그 함수들을 허브와 같은 순서로 부른다. android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`).
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.ui.Strings
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StoredFirstTest {
    private val storedRooms = listOf(
        RoomUi(
            "family", joined = true, halted = null, unread = true,
            messages = listOf(MessageUi(1, "dad-android-bbbbbb", "m1", mine = true), MessageUi(2, "mom-iphone-aaaaaa", "t2", mine = false)),
        ),
        RoomUi("kids", joined = true, halted = null, messages = emptyList(), unread = false),
    )

    /** `start()` 가 `Starting` 을 찍고 `boot` 가 저장된 것(기기 ID · 방 목록)을 화면 상태에 실은 모습 — `probe` 는 아직 부르지 않았다. */
    private fun booted(rooms: List<RoomUi> = storedRooms) = HubUi(phase = Phase.Starting, deviceId = "dad-android-bbbbbb", rooms = rooms)

    /** 저장된 신원(로비 슬롯) + 방 → `probe` 결과가 하나도 없는 상태에서 이미 `Starting` 이 아니다. */
    @Test fun storedIdentityAndRoomsLeaveStartingBeforeAnyProbeResult() {
        val shown = StoredFirst.loaded(booted(), identityStored = true)
        assertEquals<Phase>(Phase.Stored, shown.phase)
        assertEquals(storedRooms, shown.rooms, "저장된 목록·대화가 그대로 보인다")
        assertTrue(shown.connecting, "「연결 중입니다…」 표시(기존 `connecting`)")
        assertNull(shown.lobbyLive, "릴레이가 답한 값은 아직 없다")
        assertFalse(StoredFirst.live(shown.phase), "세션 확인 전")
    }

    /** 처음 실행(로비 슬롯 없음) · 방 없음은 전과 같다 — `Starting` 에 남아 `probe` 를 기다리고, 성공하면 `Ready`. */
    @Test fun firstRunAndRoomlessDeviceStillWaitForTheProbe() {
        val firstRun = booted(emptyList())
        assertEquals(firstRun, StoredFirst.loaded(firstRun, identityStored = false), "처음 실행: 아무것도 바뀌지 않는다")
        assertEquals(firstRun, StoredFirst.loaded(firstRun, identityStored = true), "신원은 있지만 방이 없다(초대 전)")
        assertEquals(booted(), StoredFirst.loaded(booted(), identityStored = false), "방 파일만 있고 신원이 없으면 열지 않는다")

        // 그 뒤는 전과 같은 흐름: 일시 실패면 시작 화면 + 연결 중, 성공하면 Ready.
        val waiting = StoredFirst.probeFailed(firstRun, classified = null, transient = true, message = "relay unreachable")
        assertEquals<Phase>(Phase.Starting, waiting.phase)
        assertTrue(waiting.connecting)
        assertNull(waiting.notice)
        val ready = StoredFirst.probeOk(waiting, live = 8, max = 8, wasWaiting = false)
        assertEquals<Phase>(Phase.Ready, ready.phase)
        assertFalse(ready.connecting)
    }

    /** `Starting` 이 아닌 단계는 건드리지 않는다(저장된 방이 있어도). */
    @Test fun onlyTheStartingPhaseIsReplaced() {
        val others: List<Phase> = listOf(Phase.Setup, Phase.Stored, Phase.WaitingEnrollment("{}"), Phase.NeedsLogin, Phase.Ready, Phase.Fatal("x"))
        for (p in others) {
            val ui = HubUi(phase = p, rooms = storedRooms)
            assertEquals(ui, StoredFirst.loaded(ui, identityStored = true), "$p")
        }
    }

    /** 저장된 화면에서 `probe` 가 일시 실패해도 저장된 목록·대화는 그대로 보이고, 나중에 성공하면 `Ready` 로 맞춰진다. */
    @Test fun transientProbeFailureKeepsStoredContentAndALaterSuccessReconciles() {
        val shown = StoredFirst.loaded(booted(), identityStored = true)

        val failed = StoredFirst.probeFailed(shown, classified = null, transient = true, message = "relay unreachable")
        assertEquals<Phase>(Phase.Stored, failed.phase)
        assertEquals(storedRooms, failed.rooms)
        assertTrue(failed.connecting)
        assertNull(failed.notice, "일시 실패는 알림을 띄우지 않는다")
        assertFalse(StoredFirst.live(failed.phase))
        // 다음 probe(3틱 뒤)도 실패 — 달라지는 것이 없다.
        assertEquals(failed, StoredFirst.probeFailed(failed, classified = null, transient = true, message = "relay unreachable"))

        val ready = StoredFirst.probeOk(failed, live = 6, max = 8, wasWaiting = false)
        assertEquals<Phase>(Phase.Ready, ready.phase)
        assertEquals(storedRooms, ready.rooms, "방 목록은 그대로 — 새 글은 그 뒤 틱의 poll 이 같은 상태 흐름으로 더한다")
        assertFalse(ready.connecting)
        assertEquals(6, ready.lobbyLive)
        assertEquals(8, ready.lobbyMax)
        assertNull(ready.notice)
        assertTrue(StoredFirst.live(ready.phase))
    }

    /** 릴레이가 세션·기기를 거절하면(401 · 403 등록 대기) 저장된 화면은 그 단계에 자리를 내준다 — 전과 같은 분류 결과를 그대로 따른다. */
    @Test fun storedScreenGivesWayWhenTheRelayRefusesTheSession() {
        val shown = StoredFirst.loaded(booted(), identityStored = true)

        val login = StoredFirst.probeFailed(shown, classified = Phase.NeedsLogin, transient = false, message = "relay status 401")
        assertEquals<Phase>(Phase.NeedsLogin, login.phase)
        assertFalse(login.connecting)
        assertNull(login.notice, "분류된 단계는 화면이 설명한다")
        assertFalse(StoredFirst.live(login.phase))

        val enroll = Phase.WaitingEnrollment("{}")
        val waiting = StoredFirst.probeFailed(shown, classified = enroll, transient = false, message = "relay error 403: device_subject_mismatch")
        assertEquals<Phase>(enroll, waiting.phase)
        assertFalse(StoredFirst.live(waiting.phase))
        // 등록 대기에서 probe 가 성공하면 「등록되었습니다」 알림과 함께 Ready(전과 같다).
        val ready = StoredFirst.probeOk(waiting, live = 0, max = 8, wasWaiting = true)
        assertEquals<Phase>(Phase.Ready, ready.phase)
        assertEquals(Strings.enrolledNow, ready.notice)
    }

    /** 분류되지 않은 영구 오류: 저장된 화면은 남고 여전히 세션 확인 전이다(표시 유지 + 사유 알림). 시작 화면에서는 전과 같다. */
    @Test fun unclassifiedPermanentFailureLeavesTheStoredScreenNotLive() {
        val shown = StoredFirst.loaded(booted(), identityStored = true)
        val failed = StoredFirst.probeFailed(shown, classified = null, transient = false, message = "boom")
        assertEquals<Phase>(Phase.Stored, failed.phase)
        assertEquals(storedRooms, failed.rooms)
        assertTrue(failed.connecting, "Ready 가 아닌 동안 「연결 중」 표시가 남는다")
        assertEquals("boom", failed.notice)
        assertFalse(StoredFirst.live(failed.phase))

        val starting = StoredFirst.probeFailed(booted(emptyList()), classified = null, transient = false, message = "boom")
        assertEquals<Phase>(Phase.Starting, starting.phase)
        assertFalse(starting.connecting)
        assertEquals("boom", starting.notice)
    }

    /** 보내기·첨부·참여 요청·읽음 올리기의 허브 쪽 문(`DeviceHub.live`): `Ready` 에서만 열린다 — 저장된 화면(`Stored`)에서는 닫혀 있다. */
    @Test fun sessionActionsAreGatedUntilReady() {
        assertTrue(StoredFirst.live(Phase.Ready))
        val notLive: List<Phase> = listOf(Phase.Setup, Phase.Starting, Phase.Stored, Phase.WaitingEnrollment("{}"), Phase.NeedsLogin, Phase.Fatal("x"))
        for (p in notLive) assertFalse(StoredFirst.live(p), "$p")
    }
}
