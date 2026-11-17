// 대화방 → 대화 목록 「넓은 뒤로가기」 스와이프 판정(순수 로직, Linux `swift test`).
// 오너 2026-11-04: iOS 기본 뒤로가기는 화면 왼쪽 끝(약 20pt)에서 시작해야만 된다 — 화면 왼쪽 2/5 안 어디서 시작해도 목록으로 가게(#677).
// 오너 2026-11-05: TestFlight 0.1.0 (91)을 써 본 뒤 3/5 까지 넓힘.
// 방식(B, 오너 선택): 손가락을 따라 화면이 밀리지는 않는다. 오른쪽으로 충분히 밀고 **손을 떼면** 일반 뒤로가기 애니메이션으로 돌아간다.
// 손가락 따라 밀기(A)는 iOS 16~25 에서 비공개 API 가 필요해 쓰지 않는다. 기본 가장자리 스와이프는 그대로 둔다.
//
// 판정(모두 만족해야 뒤로):
//   - 시작점이 화면 왼쪽 3/5 안(`startZoneFraction`)
//   - 오른쪽으로 `minimumDistance` 이상 이동
//   - 가로 이동이 세로 이동의 `horizontalDominance` 배보다 큼 — 타임라인 세로 스크롤·비스듬한 끌기는 뒤로가지 않는다
//   - #829(오너 2026-11-17): 시작점이 **가로로 넘치는 블록**(표·코드) 위가 아님 — 그 끌기는 블록의 가로 스크롤 몫이다.
//     종전엔 긴 표를 오른쪽으로 되밀면 표가 움직이면서 목록으로도 나갔다. 화면보다 좁아 넘치지 않는 표는 종전대로 뒤로간다.
import Foundation

public enum BackSwipe {
    /// 시작점이 이 비율 안(화면 왼쪽부터)이어야 한다 — 3/5.
    public static let startZoneFraction = 0.6
    /// 오른쪽으로 이만큼(pt) 이상 밀어야 한다.
    public static let minimumDistance = 80.0
    /// 가로 이동이 세로 이동의 이 배수보다 커야 한다.
    public static let horizontalDominance = 1.5

    /// - Parameters:
    ///   - startX: 끌기를 시작한 x(화면 왼쪽 = 0, pt)
    ///   - width: 화면(타임라인) 너비(pt). 아직 재지 못했으면(0 이하) 뒤로가지 않는다.
    ///   - dx: 오른쪽(+)으로 움직인 거리
    ///   - dy: 아래(+)·위(-)로 움직인 거리
    ///   - startedOnSideScroll: 시작점이 가로로 넘치는 블록 위였다(`startsOnSideScroll`) — true 면 뒤로가지 않는다(#829)
    public static func shouldGoBack(startX: Double, width: Double, dx: Double, dy: Double,
                                    startedOnSideScroll: Bool = false) -> Bool {
        guard !startedOnSideScroll else { return false }
        guard width > 0, startX >= 0 else { return false }
        guard startX <= width * startZoneFraction else { return false }
        guard dx >= minimumDistance else { return false }
        return dx > abs(dy) * horizontalDominance
    }

    /// 내용이 칸보다 이만큼(pt) 넘게 넓어야 "옆으로 밀리는" 블록으로 본다 — 반올림 차이로 좁은 표가 걸리지 않게.
    public static let overflowTolerance = 1.0

    /// 블록(표·코드)의 내용이 칸보다 넓어 실제로 옆으로 밀리는가(#829). 넘치지 않는 블록 위 끌기는 종전대로 뒤로가기 몫이다.
    public static func overflowsSideways(contentWidth: Double, viewportWidth: Double) -> Bool {
        viewportWidth > 0 && contentWidth > viewportWidth + overflowTolerance
    }

    /// 끌기 시작점이 가로로 넘치는 블록 위인가(#829). `blocks` 와 시작점은 같은 좌표(타임라인 칸, 왼쪽 위 = 0,0)여야 한다.
    /// 경계 포함(`SwipeReply.Zone.contains`) — 표 가장자리에서 시작한 끌기도 표 넘기기로 본다.
    public static func startsOnSideScroll(x: Double, y: Double, blocks: [SwipeReply.Zone]) -> Bool {
        blocks.contains { $0.contains(x: x, y: y) }
    }
}
