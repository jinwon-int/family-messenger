// 전체 화면 사진 보기 「위로 밀어 닫기」 판정(순수 로직, Linux `swift test`).
// 오너 2026-11-05: 사진은 한 번 탭하면 닫힌다 — 아래에서 위로 밀어도 닫히게.
// 앱(`ZoomableImageView`)은 확대하지 않은(줌 1) 상태에서만 이 끌기를 받는다 — 확대 중 한 손가락 끌기는 사진 이동이다.
// 끄는 동안 사진이 손가락을 따라 위로 올라가고, 손을 뗄 때 이 판정이 참이면 닫고 아니면 제자리로 돌아간다.
//
// 판정(모두 만족해야 닫음):
//   - 위로 `minimumDistance` 이상 이동(아래로 끌기는 닫지 않는다)
//   - 세로 이동이 가로 이동의 `verticalDominance` 배보다 큼 — 비스듬한 끌기는 닫지 않는다
import Foundation

public enum PhotoSwipeDismiss {
    /// 위로 이만큼(pt) 이상 밀어야 한다.
    public static let minimumDistance = 80.0
    /// 세로 이동이 가로 이동의 이 배수보다 커야 한다.
    public static let verticalDominance = 1.5

    /// - Parameters:
    ///   - dx: 오른쪽(+)·왼쪽(-)으로 움직인 거리(pt)
    ///   - dy: 아래(+)·위(-)로 움직인 거리(pt) — UIKit 좌표
    public static func shouldDismiss(dx: Double, dy: Double) -> Bool {
        let up = -dy
        guard up >= minimumDistance else { return false }
        return up > abs(dx) * verticalDominance
    }

    /// 끄는 동안 사진을 올릴 거리 — 위로만 따라간다(아래로 끌면 제자리).
    public static func followOffset(dy: Double) -> Double { min(0, dy) }
}
