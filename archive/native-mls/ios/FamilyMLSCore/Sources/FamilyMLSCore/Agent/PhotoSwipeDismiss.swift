// 전체 화면 사진 보기 「위·아래로 밀어 닫기」 판정(순수 로직, Linux `swift test`).
// 오너 2026-11-05: 사진은 한 번 탭하면 닫힌다 — 아래에서 위로 밀어도 닫히게(#678), 위에서 아래로 쓸어내려도 닫히게.
// 앱(`ZoomableImageView`)은 확대하지 않은(줌 1) 상태에서만 이 끌기를 받는다 — 확대 중 한 손가락 끌기는 사진 이동이다.
// 손을 뗄 때 이 판정이 참이면 한 번 탭 닫기와 똑같이 닫는다(오너 2026-11-05 build 94 "한 번 탭해서 꺼질 때랑 똑같이") —
// 끄는 동안 사진은 따라 움직이지 않고, 옅어짐·밀어내기 애니메이션(#681 dragAlpha/exitDuration)은 없앴다.
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
}
