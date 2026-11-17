// 대화 읽기 ↑/↓ 픽셀 이동(설정 「↑/↓ 키 이동」 작게·보통·크게, `HardwareKeys.pixelScrollTarget`)을 위해 타임라인 SwiftUI `ScrollView`
// 뒤의 `UIScrollView` 를 쥔다. 왜: 앱 대상이 iOS 16 이라 SwiftUI 에 픽셀 단위 스크롤 명령이 없다(`ScrollViewReader.scrollTo` 는 행 단위).
// 못 찾으면(핸들이 비면) 호출자가 종전 말풍선 단위로 대신한다 — 이 파일이 깨져도 ↑/↓ 는 종전처럼 동작한다.
import SwiftUI
import UIKit
import FamilyMLSCore

/// 참조 상자(`ScrollTracking` 과 같은 이유 — 바꿔도 body 를 다시 그리지 않는다).
final class TimelineScrollHandle {
    weak var scrollView: UIScrollView?

    /// 아직 창에 붙어 있는 스크롤 뷰만.
    var attached: UIScrollView? {
        guard let scrollView, scrollView.window != nil else { return nil }
        return scrollView
    }
}

extension TimelineScrollHandle {
    /// #829: 지금 화면에 올라와 있는 **가로로 넘치는** 블록(표·코드 — SwiftUI `ScrollView(.horizontal)` 뒤의 `UIScrollView`)의 보이는 영역.
    /// 좌표는 타임라인 칸(왼쪽 위 = 0,0) — 타임라인 `ScrollView` 에 붙은 넓은 뒤로가기 제스처의 `.local` 과 같은 기준이다(그 사이에
    /// 크기를 바꾸는 수정자가 없다). 끌기마다 한 번만 부른다(프레임마다 X). 스크롤 뷰를 못 쥐었으면 빈 배열 — 종전 동작 그대로.
    var sideScrollBlocks: [SwipeReply.Zone] {
        guard let timeline = attached else { return [] }
        var blocks: [SwipeReply.Zone] = []
        var pending = timeline.subviews
        while let view = pending.popLast() {
            guard !view.isHidden else { continue }
            guard let scroll = view as? UIScrollView else {
                pending.append(contentsOf: view.subviews)
                continue
            }
            // 블록 안쪽은 더 내려가지 않는다. 넘치지 않는(밀리지 않는) 블록은 세지 않는다 — 그 위 끌기는 종전대로 뒤로가기.
            guard scroll.isScrollEnabled,
                  BackSwipe.overflowsSideways(contentWidth: Double(scroll.contentSize.width),
                                              viewportWidth: Double(scroll.bounds.width))
            else { continue }
            // `bounds` 의 원점은 스크롤 위치라, 블록의 보이는 칸을 타임라인 내용 좌표로 옮긴 뒤 타임라인 스크롤 위치를 빼면 칸 좌표가 된다.
            let visible = scroll.convert(scroll.bounds, to: timeline)
                .offsetBy(dx: -timeline.bounds.minX, dy: -timeline.bounds.minY)
            blocks.append(SwipeReply.Zone(visible))
        }
        return blocks
    }
}

/// 타임라인 **내용 맨 위**(행 바깥)에 투명하게 깐다 — 창에 붙을 때 위로 올라가며 처음 만나는 `UIScrollView`(= 타임라인)를 핸들에 적는다.
/// 행 안에 두지 않는다: 표·코드 블록의 가로 스크롤 뷰를 먼저 만날 수 있다.
struct TimelineScrollViewFinder: UIViewRepresentable {
    let handle: TimelineScrollHandle

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.handle = handle
        return view
    }

    func updateUIView(_ view: FinderView, context: Context) {
        view.handle = handle
        view.locate()
    }

    final class FinderView: UIView {
        var handle: TimelineScrollHandle?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            locate()
        }

        func locate() {
            guard window != nil, let handle, handle.attached == nil else { return }
            var view = superview
            while let current = view {
                if let scroll = current as? UIScrollView {
                    handle.scrollView = scroll
                    return
                }
                view = current.superview
            }
        }
    }
}
