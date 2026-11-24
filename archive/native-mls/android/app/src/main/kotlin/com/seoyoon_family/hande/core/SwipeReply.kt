// 말풍선 「밀어서 답장」 판정(#880) — iOS FamilyMLSCore `SwipeReply` 의 Android 판. android.* 없이 JVM 에서 돈다(SwipeReplyTest).
package com.seoyoon_family.hande.core

import kotlin.math.abs
import kotlin.math.min
import kotlin.math.sqrt

/**
 * 말풍선을 **왼쪽**으로 밀면 그 말풍선에 답장(iOS 오너 2026-11-09 규칙 그대로, 단위만 pt → dp).
 * 말풍선은 손가락을 따라 왼쪽으로 밀리고(최대 [MAX_OFFSET]), [TRIGGER_DISTANCE] 를 넘기면 답장 아이콘이 켜지고(진동 한 번)
 * 손을 떼면 답장 띠가 열린다. 그 전에 손을 떼거나 되돌리면 아무 일도 없다.
 *
 * 축 고정: 끌기가 처음 [LOCK_DISTANCE] 이상 움직인 순간 가로 우세 + 왼쪽이면 답장 끌기, 아니면 그 끌기 동안은 무시한다 —
 * 타임라인 세로 스크롤 중에 말풍선이 옆으로 흔들리지 않게. 손을 뗄 때는 이미 시작에서 의도를 확인했으므로 각도 여유([END_DOMINANCE])를 준다(#745).
 * Android 말풍선에는 옆으로 스크롤되는 블록(iOS 에이전트 카드의 표·코드)이 없어 그 제외 규칙은 두지 않는다.
 */
object SwipeReply {
    /** 끌기의 축을 정하는 최소 이동(dp). */
    const val LOCK_DISTANCE = 12.0
    /** 왼쪽으로 이만큼(dp) 이상 밀고 손을 떼면 답장. */
    const val TRIGGER_DISTANCE = 60.0
    /** 말풍선이 밀려 보이는 최대 거리(dp). 문턱을 넘은 뒤로는 저항([OVERSHOOT_RATIO])을 준다. */
    const val MAX_OFFSET = 80.0
    const val OVERSHOOT_RATIO = 0.3
    /** 가로 이동이 세로 이동의 이 배수보다 커야 답장 끌기로 고정한다. */
    const val HORIZONTAL_DOMINANCE = 1.5
    /** 손을 뗄 때의 각도 여유(#745) — 엄지 궤적이 위로 휘어도(약 53°까지) 거리만 넘으면 답장. */
    const val END_DOMINANCE = 0.75

    enum class Axis {
        /** 왼쪽 가로 끌기 — 말풍선을 민다. */
        REPLY,
        /** 세로 스크롤·오른쪽·비스듬한 끌기 — 이 끌기 동안 말풍선은 움직이지 않는다. */
        IGNORE,
    }

    /** 끌기 첫 감지 때 한 번 정한다. 아직 [LOCK_DISTANCE] 만큼 움직이지 않았으면 null(다음 변화에서 다시 판단). */
    fun axis(dx: Double, dy: Double): Axis? {
        if (sqrt(dx * dx + dy * dy) < LOCK_DISTANCE) return null
        return if (dx < 0 && abs(dx) > abs(dy) * HORIZONTAL_DOMINANCE) Axis.REPLY else Axis.IGNORE
    }

    /** 말풍선을 그릴 가로 이동(dp, 0 또는 음수). 오른쪽 끌기는 0, 문턱까지는 손가락 그대로, 그 뒤는 저항 + [MAX_OFFSET] 상한. */
    fun offset(dx: Double): Double {
        if (dx >= 0) return 0.0
        val pulled = -dx
        if (pulled <= TRIGGER_DISTANCE) return -pulled
        return -min(MAX_OFFSET, TRIGGER_DISTANCE + (pulled - TRIGGER_DISTANCE) * OVERSHOOT_RATIO)
    }

    /** 손을 뗄 때(또는 끌기 중 아이콘을 켤 때) 답장 여부. 축은 시작 때 이미 정했다 — 여기서는 거리와 넉넉한 각도만. */
    fun shouldReply(dx: Double, dy: Double): Boolean = dx <= -TRIGGER_DISTANCE && abs(dx) >= abs(dy) * END_DOMINANCE
}
