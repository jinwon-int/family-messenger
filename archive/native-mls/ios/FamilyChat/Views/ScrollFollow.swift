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

    /// #497 A6: 바닥 앵커(iOS 17+)가 **자리를 놓쳤다** — 따라가는 중인데 바닥 표지가 화면 아래 끝에서 `nearBottom` 보다 멀리 있다.
    /// build 55 오너 기록: 표지 5273 에 멈춘 채 `following=true`, 남의 새 글(`.follow`)이 와도 앵커 모드라 명령을 안 내 바닥으로 안 돌아왔다.
    /// 매 실측마다 고치면 앵커와 싸워 꿈틀거리므로(A5), **새 글이 왔을 때 한 번**만 쓴다. 표지 미측정(∞)·칸 미측정(0)이면 false.
    static func anchorLostBottom(following: Bool, sentinelBottom: Double, viewportHeight: Double) -> Bool {
        following && viewportHeight > 0 && sentinelBottom.isFinite && sentinelBottom > viewportHeight + nearBottom
    }

    // MARK: - 내용 끝을 지나 빈 화면(오너 보고 build 41: 사진 한 장에 채팅 없이 배경만)

    /// 목록 아래 여백(`.padding()` 기본값) — 맨 아래에 멈춰 있으면 바닥 표지 아래 끝 = 화면 높이 − 이 값.
    static let bottomInset: Double = 16
    /// 바닥 표지가 "맨 아래 자리"보다 이만큼 넘게 위에서 끝나면 빈 화면이다(끝에서 튕기는 정도는 넘지 않는다).
    static let blankGap: Double = 80
    /// 손을 뗀 뒤 이만큼은 튕김(rubber-band)으로 본다.
    static let bounceGrace: TimeInterval = 0.6

    /// 내용이 화면보다 긴데 바닥 표지가 화면 아래 끝보다 한참 위에서 끝났다 = 스크롤 위치가 **내용 끝을 지났다**(빈 화면).
    /// 위 행들의 실제·추정 높이가 줄면(LazyVStack 미배치 행 추정치 변화 등) 위치는 그대로라 내용이 위로 빠져나간다. 종전 보정
    /// (`needsBottomCorrection`)은 표지가 화면 **아래**에 남은 경우만 봤다 — build 40 까지는 중복 스크롤 명령이 우연히 되돌렸고,
    /// #498 이 중복을 없애자 빈 화면이 남았다. 따라가기 여부와 상관없이 맞춘다(빈 화면은 머물 자리가 아니다).
    static func isPastContentEnd(sentinelBottom: Double, viewportHeight: Double, contentHeight: Double, sinceDrag: TimeInterval) -> Bool {
        viewportHeight > 0 && contentHeight > viewportHeight && sinceDrag >= bounceGrace
            && sentinelBottom < viewportHeight - bottomInset - blankGap
    }

    /// 다시 읽은 뒤 늦게 오는 높이 변화(사진 준비는 백그라운드)를 놓치지 않게 다시 재는 시점(초).
    static let verifyDelays: [TimeInterval] = [0.35, 1.0]
}

/// #497 후속(오너 보고 2026-10-28: 상대 **글** 하나에도 타임라인이 위·아래로 반복): 꼬리(lazy 아님)와 LazyVStack 의 경계.
///
/// 종전 경계는 "마지막 3행"이라 새 글마다 끝에서 3번째 행이 LazyVStack 으로 **이사**했다. LazyVStack 은 아직 배치하지 않은 행의
/// 높이를 **측정된 행의 평균**으로 추정하므로(이사한 행 = 새 측정) 새 글마다 위쪽 수백 행의 추정치가 함께 바뀌어 내용이 위로 밀리고
/// (스크롤 위치는 위 기준), `scrollTo` 가 다시 내리고, 재배치로 또 틀어졌다 — 사진이 아니어도 난다.
/// 경계를 **행 id 로 고정**하면 새 글은 늘 꼬리(실제 높이)에 붙고 LazyVStack 의 자식·측정은 그대로라 추정치가 움직이지 않는다.
enum TimelineTail {
    /// 진입 때 꼬리에 두는 행 수 = 기본 타임라인 창 전체(`AppModel.timelineLimit`).
    ///
    /// #497 A6(오너 build 55 기록, dungae 방): 꼬리 40행 + lazy 79행일 때 내용 높이 추정이 15k↔91k pt(120행!)로 폭주했다 — Δ≈5690 단위
    /// 계단으로 오르고(끌기 직후 표지 315→11675→17359 = 화면이 1만 pt 위로 튐) 몇 초에 걸쳐 기하급수적으로 줄며 돌아왔다. 또 내용 변화
    /// 없이 표지가 598↔5265(Δ≈꼬리 41행 높이)를 같은 ms 안에 왕복하다 5273 에 멈췄다(바닥 앵커가 lazy/꼬리 경계에서 자리를 놓침).
    /// 두 현상의 원천이 모두 LazyVStack 의 **미배치 행 추정치**라, 진입 때 보이는 창(120행)은 전부 실제 높이로 두어 추정 대상을 0 으로
    /// 만든다. lazy 는 #472 페이징으로 위에 붙은 과거 글에만 남는다(위로 읽는 중에만 존재). 첨부 썸네일은 `AttachmentPreviewCache`
    /// (300건·128 MiB 상한)로 유한하다.
    static let rows = AppModel.timelineLimit

    /// 꼬리가 시작하는 index. `anchor`(종전 꼬리의 첫 행 id)가 아직 `ids` 에 있으면 그 자리(과거 글을 위에 붙여도 같은 행), 없으면
    /// (진입·창 되돌림·보내던 글이 자리를 바꿈) 끝에서 `rows` 번째. 결과는 항상 `0...ids.count`.
    static func start(ids: [Int64], anchor: Int64?) -> Int {
        if let anchor, let index = ids.firstIndex(of: anchor) { return index }
        return max(0, ids.count - rows)
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
