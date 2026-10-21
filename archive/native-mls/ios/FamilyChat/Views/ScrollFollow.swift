// #398: 대화방이 최하단을 따라가야 하는지(순수 판정 — 뷰 밖에서 XCTest).
// 첨부 본체는 행이 보일 때 늦게 읽혀(#364/#367) 이미지로 바뀌며 행 높이가 커진다. 그 행이 마지막 몇 행 안에 있고
// 사용자가 위로 끌어 올리지 않았다면 다시 최하단으로 간다. 옛 사진을 보러 올라간 사람의 화면은 움직이지 않는다.
import Foundation

enum ScrollFollow {
    /// 늦게 커진 행이 이만큼 끝에 가까우면 최하단이 화면 밖으로 밀렸을 수 있다(마지막 행 + 그 위 두 행).
    static let tailRows = 3

    /// `loaded` 행이 `ids`(오래된 순)의 마지막 `tailRows` 안에 있고 `following` 이면 true.
    static func shouldRescroll(loaded: Int64, ids: [Int64], following: Bool) -> Bool {
        guard following, let index = ids.lastIndex(of: loaded) else { return false }
        return index >= ids.count - tailRows
    }

    /// 화면 키보드가 올라오면(또는 작성창이 여러 줄로 커지면) 메시지 칸이 아래에서 줄어든다. 스크롤 위치는 위 기준으로 남아
    /// 최신 메시지가 키보드 뒤로 숨는다 — 칸이 줄었고 최하단을 따라가는 중이면 다시 최하단으로 간다(오너 요청, build 28).
    /// 처음 재는 높이(`old == 0`)와 0.5pt 미만의 흔들림은 무시한다. 칸이 커질 때(키보드 내림)는 스크롤이 알아서 맞춘다.
    static func shouldRescrollOnResize(old: Double, new: Double, following: Bool) -> Bool {
        following && old > 0 && new < old - 0.5
    }

    /// 목록 **내용**이 커졌다(방 진입 직후 lazy 행이 추정 높이에서 실제 높이로 · 이미지 로딩 · 날짜 구분선) — 따라가는 중이면
    /// 최하단을 다시 맞춘다. 진입 시 `scrollTo` 는 아직 배치되지 않은 행의 추정 높이로 움직여 2~3번째 최신 글에서 멈추던
    /// 결함(오너 보고 build 30)의 수정. 처음 재는 값(`old == 0`)도 포함한다 — 첫 배치 뒤에도 한 번 더 맞춘다.
    static func shouldRescrollOnContentGrowth(old: Double, new: Double, following: Bool) -> Bool {
        following && new > old + 0.5
    }

    /// 배치가 끝난 뒤 **실측**: 바닥 표지의 아래 끝(`sentinelBottom`, 스크롤 뷰 좌표)이 화면 높이보다 아래면 아직 맨 아래가 아니다 —
    /// 따라가는 중이면 한 번 더 맞춘다. LazyVStack 의 `scrollTo` 는 아직 배치되지 않은 행의 추정 높이로 움직이므로 긴 마지막 글은
    /// 위만 보일 수 있다(오너 보고 build 32). 표지가 화면 안(또는 위)이면 맞춘 것이다.
    static func needsBottomCorrection(sentinelBottom: Double, viewportHeight: Double, following: Bool) -> Bool {
        following && viewportHeight > 0 && sentinelBottom > viewportHeight + 0.5
    }

    /// #472: 맨 위 표지가 이만큼 가까워지면 미리 과거 글을 읽는다(화면 높이의 일부 — 끝에 닿기 전에 붙여 둔다).
    static let olderPrefetch: Double = 240

    /// 위로 읽으러 올라가는 중(`following == false`)이고, 맨 위 표지의 아래 끝(`sentinelBottom`, 스크롤 뷰 좌표 — 위로 밀리면 음수)이
    /// `olderPrefetch` 안으로 들어왔고, 이미 읽는 중이 아니며, 더 읽을 것이 있으면 true. 진입 직후(따라가는 중, 표지가 화면에 있어도)는 읽지 않는다.
    static func shouldLoadOlder(sentinelBottom: Double, following: Bool, busy: Bool, exhausted: Bool) -> Bool {
        !following && !busy && !exhausted && sentinelBottom > -olderPrefetch
    }
}
