// 디자인 2차-A 문구 조립 고정(ui/Strings.kt — android.* 없음): 후보 카드 시각 줄·지문 행 접근성·승인 꺼짐 문구. iOS `Strings+Onboarding.swift` 와 같은 결과.
package com.seoyoon_family.hande.ui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class StringsTest {
    @Test fun candidateTimesShowOnlyWhatIsKnown() {
        assertEquals("요청 21:10 · 21:40에 만료", Strings.candidateTimes("21:10", "21:40"))
        assertEquals("21:40에 만료", Strings.candidateTimes(null, "21:40"), "요청 시각을 모르면 만료만")
        assertEquals("요청 21:10", Strings.candidateTimes("21:10", null))
        assertNull(Strings.candidateTimes(null, null))
    }

    @Test fun fingerprintRowLabelAndApproveGate() {
        assertEquals("3번, 1a2b 3c4d, 맞춤 표시 안 됨", Strings.fingerprintRowLabel(3, "1a2b 3c4d", ticked = false))
        assertEquals("3번, 1a2b 3c4d, 맞춤 표시 됨", Strings.fingerprintRowLabel(3, "1a2b 3c4d", ticked = true))
        assertEquals("1번, 1a2b 3c4d", Strings.fingerprintRowLabel(1, "1a2b 3c4d", ticked = null), "표시가 없는 등록 화면")
        assertEquals("8줄을 모두 맞춰 보세요", Strings.approveDisabled(8))
        assertEquals("같으면 눌러 표시하세요 · 3 / 8", Strings.approveProgress(3, 8))
        assertEquals("다른 기기의 승인을 기다리는 중 · 21:40까지", Strings.enrollWaitingSiblingUntil("21:40"))
        assertEquals("4단계 중 2단계", Strings.onboardingStep(2, Strings.onboardingSteps))
    }
}
