// 전체 화면 사진 줌 — UIKit `UIScrollView` 줌(핀치 위치 기준 확대·관성·바운스, 두 번 탭은 탭 위치로 확대/원래,
// 한 번 탭은 `onSingleTap` — 사진 보기 닫기, 줌 1 에서 위·아래로 밀기는 `onSwipeDismiss` — 역시 닫기, 오너 2026-11-05).
// SwiftUI `MagnificationGesture` 는 iOS 16 에서 거칠다(ryohey/Zoomable README caveat: 핀치 위치가 좌상단 고정;
// home-assistant/ios#4592 도 순수 SwiftUI 제스처에서 UIKit 으로 전환) — 오너 보고 build 32 "투박하고 되다 안 되다".
// UIKit 전용(Linux 스모크 목록에 넣지 말 것).
import SwiftUI
import UIKit
import FamilyMLSCore

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var maxZoom: CGFloat = 4
    var doubleTapZoom: CGFloat = 2.5
    /// 한 번 탭(두 번 탭이 아닐 때만). 사진 보기에서는 닫기.
    var onSingleTap: (() -> Void)? = nil
    /// 줌 1 에서 위나 아래로 밀어 손을 뗐을 때(판정 `PhotoSwipeDismiss`). 사진 보기에서는 닫기.
    var onSwipeDismiss: (() -> Void)? = nil

    func makeUIView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = maxZoom
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .black
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.doubleTapZoom = doubleTapZoom
        context.coordinator.onSingleTap = onSingleTap
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        // 한 번 탭은 두 번 탭이 실패한 뒤에만 인식한다 — 두 번 탭 확대가 닫기로 새지 않는다.
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTapped(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)
        // 위·아래로 밀어 닫기 — 한 손가락, 줌 1 에서 세로로 시작한 끌기만(`gestureRecognizerShouldBegin`). 확대 중 끌기(사진 이동)와 섞이지 않는다.
        let swipe = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        swipe.maximumNumberOfTouches = 1
        swipe.delegate = context.coordinator
        scroll.addGestureRecognizer(swipe)
        context.coordinator.onSwipeDismiss = onSwipeDismiss
        // 처음·회전 때 화면 크기에 맞춰 잡는다(makeUIView 시점엔 bounds 가 0).
        scroll.onLayout = { [weak scroll, coordinator = context.coordinator] in
            if let scroll { coordinator.fit(scroll) }
        }
        return scroll
    }

    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onSwipeDismiss = onSwipeDismiss
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            context.coordinator.fittedSize = .zero
            scroll.setNeedsLayout()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// `layoutSubviews` 를 코디네이터에 알리는 UIScrollView.
    final class ZoomScrollView: UIScrollView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var imageView: UIImageView?
        var doubleTapZoom: CGFloat = 2.5
        var onSingleTap: (() -> Void)?
        var onSwipeDismiss: (() -> Void)?
        var fittedSize: CGSize = .zero

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func singleTapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onSingleTap?()
        }

        /// 위·아래로 밀기 끌기는 줌 1(확대 안 함)에서, 세로로 시작했을 때만 받는다. 탭 인식기에는 delegate 를 두지 않으므로 여기 오는 것은 이 끌기뿐이다.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let scroll = pan.view as? UIScrollView else { return true }
            guard onSwipeDismiss != nil, scroll.zoomScale <= scroll.minimumZoomScale + 0.01 else { return false }
            let velocity = pan.velocity(in: scroll)
            return abs(velocity.y) > abs(velocity.x)
        }

        /// 스크롤 뷰 자체의 끌기·핀치와 함께 인식한다(줌 1 에서는 내용이 화면 크기라 스크롤 뷰는 움직이지 않는다).
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// 밀어 닫기는 한 번 탭 닫기와 똑같이 닫는다(오너 2026-11-05 build 94: "한 번 탭해서 꺼질 때랑 똑같이").
        /// 끄는 동안 사진은 움직이지 않는다. 손을 떼었을 때 판정(`PhotoSwipeDismiss`)이 참이면 `onSwipeDismiss` — 화면은 기본 닫힘 애니메이션으로 닫힌다.
        /// 두 번째 손가락이 닿거나 핀치가 시작되면 이 끌기를 취소한다(닫지 않는다).
        @objc func panned(_ pan: UIPanGestureRecognizer) {
            guard let scroll = pan.view as? UIScrollView else { return }
            switch pan.state {
            case .changed:
                if scroll.isZooming || pan.numberOfTouches > 1 {
                    pan.isEnabled = false   // → .cancelled 로 끝난다
                    pan.isEnabled = true
                }
            case .ended:
                let moved = pan.translation(in: scroll.superview ?? scroll)
                if PhotoSwipeDismiss.shouldDismiss(dx: Double(moved.x), dy: Double(moved.y)) {
                    onSwipeDismiss?()
                }
            default:
                break
            }
        }

        /// 줌 1 = 화면에 맞춤(이미지 뷰 = 화면 크기, aspect-fit 으로 안에 그린다). 화면 크기가 바뀔 때만 다시 잡는다.
        func fit(_ scroll: UIScrollView) {
            guard let imageView, scroll.bounds.size != .zero, scroll.bounds.size != fittedSize else { return }
            fittedSize = scroll.bounds.size
            scroll.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: scroll.bounds.size)
            scroll.contentSize = scroll.bounds.size
            scroll.contentOffset = .zero
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView, let imageView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                // 탭한 곳이 가운데 오게 그 주변 사각형으로 확대한다.
                let point = recognizer.location(in: imageView)
                let scale = min(scroll.maximumZoomScale, doubleTapZoom)
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
