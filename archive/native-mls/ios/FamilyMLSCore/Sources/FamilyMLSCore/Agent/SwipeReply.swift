// 말풍선 「밀어서 답장」 판정(순수 로직, Linux `swift test`).
// 오너 2026-11-09: 말풍선을 옆으로 밀면 그 말풍선에 답장(꾹 누르기 메뉴 「답장」 #727 과 같은 결과).
//
// 방향은 **왼쪽**(손가락이 오른쪽 → 왼쪽)만 쓴다. 오른쪽 밀기는 이미 「넓은 뒤로가기」(`BackSwipe`, 화면 왼쪽 3/5 에서 오른쪽으로)
// 몫이라 겹치지 않게 한다. 말풍선은 손가락을 따라 왼쪽으로 밀리고(최대 `maxOffset`), `triggerDistance` 를 넘기면 답장 아이콘이
// 켜지고(진동 한 번) 손을 떼면 답장 띠가 열린다. 그 전에 손을 떼거나 되돌리면 아무 일도 없다.
//
// 축 고정: 끌기가 처음 감지된 순간(`lockDistance` 이상) 가로 우세 + 왼쪽이면 답장 끌기, 아니면 그 끌기 동안은 무시한다 —
// 타임라인 세로 스크롤 중에 말풍선이 옆으로 흔들리지 않게.
//
// #745(오너 2026-11-10 「최신 말풍선은 되는데 두 번째부터 잘 안 됨」): 시뮬레이터 실측(정지·스크롤 뒤·에이전트 카드 최신/이전 모두 성공)으로
// 행 위치에 따른 코드 분기는 없었다. 위쪽 말풍선을 엄지로 밀면 궤적이 비스듬하고 위로 휘는데, 종전 판정(시작·끝 모두 1.5배)이 그 끌기를
// 놓쳤고 밀리는 동안 타임라인이 같이 세로로 움직여 말풍선이 손가락 아래에서 빠져나갔다 → 시작 1.2배 · 끝 0.75배 + 밀기 중 세로 스크롤 잠금.
import Foundation

public enum SwipeReply {
    /// 끌기의 축을 정하는 최소 이동(pt) — 제스처 `minimumDistance` 로도 쓴다.
    public static let lockDistance = 12.0
    /// 왼쪽으로 이만큼(pt) 이상 밀고 손을 떼면 답장.
    public static let triggerDistance = 60.0
    /// 말풍선이 밀려 보이는 최대 거리(pt). `triggerDistance` 를 넘은 뒤로는 저항(`overshootRatio`)을 준다.
    public static let maxOffset = 80.0
    public static let overshootRatio = 0.3
    /// 가로 이동이 세로 이동의 이 배수보다 커야 한다(`BackSwipe` 와 같은 값) — iOS 16·17 SwiftUI 경로의 축 고정.
    public static let horizontalDominance = 1.5
    /// iOS 18+ 팬의 시작 판정 배수(#745). 1.5 는 화면 위쪽 말풍선을 엄지로 밀 때 생기는 비스듬한 출발을 놓쳤다 — 세로 스크롤은
    /// 세로 성분이 압도적이라(60° 이상) 1.2(약 40°)로 낮춰도 스크롤을 빼앗지 않는다.
    public static let beginDominance = 1.2
    /// 손을 뗄 때의 각도 여유(#745): 시작에서 이미 왼쪽 가로 의도를 확인했고 밀리는 동안 타임라인 세로 스크롤은 잠겨 있으므로
    /// (`SwipeReplyPan`), 엄지 궤적이 위로 휘어도(약 53°까지) 거리만 넘으면 답장한다. 종전 1.5 는 위쪽 말풍선에서 답장이 자주 빠졌다.
    public static let endDominance = 0.75

    public enum Axis: Equatable {
        /// 왼쪽 가로 끌기 — 말풍선을 민다.
        case reply
        /// 세로 스크롤·오른쪽·비스듬한 끌기 — 이 끌기 동안 말풍선은 움직이지 않는다.
        case ignore
    }

    /// 끌기 첫 감지 때 한 번 정한다. 아직 `lockDistance` 만큼 움직이지 않았으면 nil(다음 변화에서 다시 판단).
    public static func axis(dx: Double, dy: Double) -> Axis? {
        guard (dx * dx + dy * dy).squareRoot() >= lockDistance else { return nil }
        return dx < 0 && abs(dx) > abs(dy) * horizontalDominance ? .reply : .ignore
    }

    /// iOS 18+ UIKit 팬의 시작 판정(시작 순간 속도, pt/s): 왼쪽 + 가로 우세일 때만 시작한다. 0 속도(정지)·세로·오른쪽은 시작하지 않아
    /// 스크롤 팬이 받는다 — 오너 2026-11-09 TestFlight 107 「말풍선 위에서 위아래로 안 움직임」 수정.
    public static func shouldBegin(vx: Double, vy: Double) -> Bool {
        vx < 0 && abs(vx) > abs(vy) * beginDominance
    }

    /// 말풍선을 그릴 가로 이동(pt, 0 또는 음수). 오른쪽 끌기는 0, 문턱까지는 손가락 그대로, 그 뒤는 저항 + `maxOffset` 상한.
    public static func offset(dx: Double) -> Double {
        guard dx < 0 else { return 0 }
        let pulled = -dx
        if pulled <= triggerDistance { return -pulled }
        return -min(maxOffset, triggerDistance + (pulled - triggerDistance) * overshootRatio)
    }

    /// 손을 뗄 때(또는 끌기 중 아이콘을 켤 때) 답장 여부. 축은 시작 때 이미 정했다 — 여기서는 거리와 넉넉한 각도(`endDominance`)만.
    public static func shouldReply(dx: Double, dy: Double) -> Bool {
        dx <= -triggerDistance && abs(dx) >= abs(dy) * endDominance
    }

    /// 에이전트 카드 안의 옆으로 미는 블록(코드·표 — `ScrollView(.horizontal)`) 한 개의 영역(pt, 행 좌표계 `rowSpace`).
    /// 종전(#730)엔 이런 블록이 하나라도 있으면 카드 전체에서 밀어서 답장을 껐다. #737(오너 2026-11-10 「소교 보고서에서 밀어서 답장이
    /// 안 됨」): 에이전트 보고서는 표가 흔해 답장이 가장 많은 카드에서 밀기가 늘 꺼졌다 → **시작점이 이 영역 안일 때만** 끈다.
    public struct Zone: Equatable, Sendable {
        public let minX: Double
        public let minY: Double
        public let maxX: Double
        public let maxY: Double

        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }

        /// 경계 포함 — 표 가장자리에서 시작한 끌기도 표 넘기기 몫으로 둔다(넘기기를 답장으로 오인하는 쪽이 더 나쁘다).
        public func contains(x: Double, y: Double) -> Bool {
            x >= minX && x <= maxX && y >= minY && y <= maxY
        }
    }

    /// 표·코드 영역을 재는 행 좌표계 이름 — 영역 보고(`AgentViews`)와 끌기 시작점(`SwipeToReply`)이 같은 기준을 쓴다.
    public static let rowSpace = "swipeReplyRow"

    /// 끌기 시작점(행 좌표)이 옆으로 미는 블록 위면 true — 이 끌기는 그 블록의 가로 스크롤 몫이라 밀어서 답장을 시작하지 않는다.
    /// 영역 밖(제목·문단·목록·카드 여백)에서 시작한 왼쪽 밀기는 종전처럼 답장.
    public static func startsInSideScroll(x: Double, y: Double, zones: [Zone]) -> Bool {
        zones.contains { $0.contains(x: x, y: y) }
    }
}
