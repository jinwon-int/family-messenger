// 대화방 → 대화 목록 「넓은 뒤로가기」 스와이프 판정(순수 로직, Linux `swift test`).
// 오너 2026-11-04: iOS 기본 뒤로가기는 화면 왼쪽 끝(약 20pt)에서 시작해야만 된다 — 화면 왼쪽 2/5 안 어디서 시작해도 목록으로 가게.
// 방식(B, 오너 선택): 손가락을 따라 화면이 밀리지는 않는다. 오른쪽으로 충분히 밀고 **손을 떼면** 일반 뒤로가기 애니메이션으로 돌아간다.
// 손가락 따라 밀기(A)는 iOS 16~25 에서 비공개 API 가 필요해 쓰지 않는다. 기본 가장자리 스와이프는 그대로 둔다.
//
// 판정(모두 만족해야 뒤로):
//   - 시작점이 화면 왼쪽 2/5 안(`startZoneFraction`)
//   - 오른쪽으로 `minimumDistance` 이상 이동
//   - 가로 이동이 세로 이동의 `horizontalDominance` 배보다 큼 — 타임라인 세로 스크롤·비스듬한 끌기는 뒤로가지 않는다
import Foundation

public enum BackSwipe {
    /// 시작점이 이 비율 안(화면 왼쪽부터)이어야 한다 — 2/5.
    public static let startZoneFraction = 0.4
    /// 오른쪽으로 이만큼(pt) 이상 밀어야 한다.
    public static let minimumDistance = 80.0
    /// 가로 이동이 세로 이동의 이 배수보다 커야 한다.
    public static let horizontalDominance = 1.5

    /// - Parameters:
    ///   - startX: 끌기를 시작한 x(화면 왼쪽 = 0, pt)
    ///   - width: 화면(타임라인) 너비(pt). 아직 재지 못했으면(0 이하) 뒤로가지 않는다.
    ///   - dx: 오른쪽(+)으로 움직인 거리
    ///   - dy: 아래(+)·위(-)로 움직인 거리
    public static func shouldGoBack(startX: Double, width: Double, dx: Double, dy: Double) -> Bool {
        guard width > 0, startX >= 0 else { return false }
        guard startX <= width * startZoneFraction else { return false }
        guard dx >= minimumDistance else { return false }
        return dx > abs(dy) * horizontalDominance
    }
}
