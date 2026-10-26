// #398: 대화방이 최하단을 따라가야 하는지(순수 판정 — 뷰 밖에서 XCTest).
// 첨부 본체는 행이 보일 때 늦게 읽혀(#364/#367) 이미지로 바뀌며 행 높이가 커진다. 그 행이 마지막 몇 행 안에 있고
// 사용자가 위로 끌어 올리지 않았다면 다시 최하단으로 간다. 옛 사진을 보러 올라간 사람의 화면은 움직이지 않는다.
// #497: 다시 읽은 뒤의 동작(`afterReload`)·맨 아래 복귀(`shouldRefollow`)·스크롤 명령 합치기(`ScrollTracking`).
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

    // MARK: - 다시 읽은 뒤 어떻게 움직일지(상대 사진 뒤 위·아래 점프 반복 수정)

    /// 다시 읽은 타임라인에 새로 생긴 행(종전에 없던 id) — 이 기기에서 보낸 글인가, 다른 사람(또는 내 다른 기기)의 글인가.
    struct Arrival: Equatable {
        var mine = false
        var others = false
    }

    /// `before` 에 없던 행을 가른다. `fromThisDevice` = 이 기기에서 보낸 글(보내는 중 포함) — 내 다른 기기의 글은 `others`.
    static func arrival(before: Set<Int64>, after: [(id: Int64, fromThisDevice: Bool)]) -> Arrival {
        var result = Arrival()
        for row in after where !before.contains(row.id) {
            if row.fromThisDevice { result.mine = true } else { result.others = true }
        }
        return result
    }

    enum ReloadAction: Equatable {
        /// 내가 보냈다 — 위로 읽던 중이어도 최하단으로(부드럽게).
        case followAnimated
        /// 따라가는 중에 남의 글이 왔다 — 애니메이션 없이 한 번. 애니메이션은 늦은 사진 로딩·실측 보정과 겹쳐 위아래로 흔들렸다.
        case follow
        /// 위로 읽는 중에 남의 글이 왔다 — 화면은 그대로, 「새 메시지」 버튼만.
        case markNewBelow
        /// 새 행이 없다(보내는 글 상태 변화·다시 그리기) — 스크롤 명령을 내지 않는다(높이가 커지면 내용 증가 보정이 맡는다).
        case stay
    }

    /// 종전에는 **어느 방이든** 신호가 오면 따라가기를 다시 켜고 애니메이션으로 내렸다 — 위로 읽던 사람도 끌려 내려가고,
    /// 사진 한 장에 스크롤 명령이 4~6개 겹쳤다.
    static func afterReload(following: Bool, arrival: Arrival) -> ReloadAction {
        if arrival.mine { return .followAnimated }
        guard arrival.others else { return .stay }
        return following ? .follow : .markNewBelow
    }

    /// 손을 뗀 뒤 이만큼 지나야 "멈춘 자리"로 본다(끄는 중에 따라가기를 다시 켜면 손가락과 싸운다).
    static let settleDelay: TimeInterval = 0.25
    /// 바닥 표지가 화면 아래 끝에서 이 안이면 "맨 아래에 있다".
    static let nearBottom: Double = 24

    /// 끌어서 따라가기가 꺼졌지만 맨 아래로 돌아와 멈췄다 — 다시 따라간다(맨 아래에서 살짝 끌기만 해도 새 글을 놓치지 않게).
    static func shouldRefollow(following: Bool, sentinelBottom: Double, viewportHeight: Double, sinceDrag: TimeInterval) -> Bool {
        !following && viewportHeight > 0 && sinceDrag >= settleDelay && sentinelBottom <= viewportHeight + nearBottom
    }
}

/// 스크롤 중 **프레임마다** 바뀌는 값과 스크롤 명령 합치기 상태. `@State` 값으로 두면 매 프레임 방 화면 body 를 다시 계산한다
/// (500행 map 여러 번) — 참조 상자에 두고 바꿔도 다시 그리지 않는다.
final class ScrollTracking {
    /// 바닥 표지의 마지막 실측(스크롤 뷰 좌표).
    var sentinelBottom: Double = .infinity
    /// 마지막 끌기 변화 시각.
    var lastDrag: Date = .distantPast
    /// 다음 런루프에 낼 스크롤 명령이 이미 있다(같은 틱의 요청은 하나로 합친다).
    var pendingScroll = false
    /// 합친 명령의 애니메이션 여부 — 하나라도 즉시면 즉시.
    var pendingAnimated = false
    /// 애니메이션 스크롤이 도는 동안(이 시각까지)은 즉시 보정을 내지 않는다 — 끝난 뒤 한 번 다시 잰다.
    var animatingUntil: Date = .distantPast

    var isAnimating: Bool { Date() < animatingUntil }

    /// 같은 런루프의 스크롤 요청을 하나로: 처음 요청이면 true(호출자가 다음 틱에 실행), 이미 있으면 애니메이션 여부만 합친다.
    func request(animated: Bool) -> Bool {
        if pendingScroll {
            pendingAnimated = pendingAnimated && animated
            return false
        }
        pendingScroll = true
        pendingAnimated = animated
        return true
    }

    /// 다음 틱: 합친 명령을 꺼낸다(애니메이션 여부).
    func take() -> Bool {
        pendingScroll = false
        return pendingAnimated
    }
}
