// 전체 화면 사진 보기 「위·아래로 밀어 닫기」 판정(순수 로직, Linux `swift test`).
// 오너 2026-11-05: 사진은 한 번 탭하면 닫힌다 — 아래에서 위로 밀어도 닫히게(#678), 위에서 아래로 쓸어내려도 닫히게.
// 앱(`ZoomableImageView`)은 확대하지 않은(줌 1) 상태에서만 이 끌기를 받는다 — 확대 중 한 손가락 끌기는 사진 이동이다.
// 끄는 동안 사진이 손가락을 따라 위아래로 움직이고, 손을 뗄 때 이 판정이 참이면 민 방향으로 내보내며 닫고 아니면 제자리로 돌아간다.
// 부드럽게(오너 2026-11-05 build 93 "닫힐 때 오두방정"): 끄는 동안 조금씩 옅어지고(`dragAlpha`), 놓으면 손가락 속도를 이어받아
// 감속하며(`exitDuration`, easeOut) 옅어진 채 나간다. 앱은 그 뒤 전체 화면 덮개를 애니메이션 없이 내린다 — 덮개가 아래로 한 번 더 미끄러지지 않게.
//
// 판정(모두 만족해야 닫음):
//   - 위 또는 아래로 `minimumDistance` 이상 이동(방향은 어느 쪽이든 같은 기준)
//   - 세로 이동이 가로 이동의 `verticalDominance` 배보다 큼 — 비스듬한 끌기는 닫지 않는다
import Foundation

public enum PhotoSwipeDismiss {
    /// 위나 아래로 이만큼(pt) 이상 밀어야 한다.
    public static let minimumDistance = 80.0
    /// 세로 이동이 가로 이동의 이 배수보다 커야 한다.
    public static let verticalDominance = 1.5

    /// - Parameters:
    ///   - dx: 오른쪽(+)·왼쪽(-)으로 움직인 거리(pt)
    ///   - dy: 아래(+)·위(-)로 움직인 거리(pt) — UIKit 좌표
    public static func shouldDismiss(dx: Double, dy: Double) -> Bool {
        let vertical = abs(dy)
        guard vertical >= minimumDistance else { return false }
        return vertical > abs(dx) * verticalDominance
    }

    /// 화면 높이만큼 끌면 이 불투명도까지 옅어진다.
    public static let minimumDragAlpha = 0.6
    /// 놓은 뒤 화면 밖까지 나가는 시간의 아래·위 한계(초).
    public static let minimumExitDuration = 0.16
    public static let maximumExitDuration = 0.3

    /// 끄는 동안 사진의 불투명도 — 위아래 같은 비율, 화면 높이 이상은 `minimumDragAlpha` 에서 멈춘다.
    public static func dragAlpha(dy: Double, height: Double) -> Double {
        guard height > 0 else { return 1 }
        let progress = min(abs(dy) / height, 1)
        return 1 - progress * (1 - minimumDragAlpha)
    }

    /// 놓은 뒤 남은 거리(pt)를 손가락 속도(pt/s)로 가는 시간 — 빠르게 튕기면 짧게, 천천히 놓으면 길게, 한계 안으로 묶는다.
    public static func exitDuration(remaining: Double, velocity: Double) -> Double {
        let speed = abs(velocity)
        guard speed > 0 else { return maximumExitDuration }
        return min(maximumExitDuration, max(minimumExitDuration, abs(remaining) / speed))
    }
}
