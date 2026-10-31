// 작성창 입력칸 — SwiftUI `TextField` 대신 UITextView 를 직접 쓴다(하드웨어 키보드 Return 을 입력칸이 스스로 처리).
//
// 왜(오너 실기기 0.1.0 (70)·(73)·(75), 아이폰 + 블루투스 키보드): SwiftUI 세로 `TextField` 는 하드웨어 Return 을 받으면 줄바꿈 대신
// 입력을 끝내 커서를 놓는다. 바깥에서 가로채기(GameController · iOS 17 `onKeyPress`)와 커서 되살리기를 차례로 해 봤지만 이 기기에서는
// 커서가 계속 사라졌다(#626·#628). UITextView 는 Return 으로 입력을 끝내지 않으므로, 입력칸 안(`pressesBegan`)에서 키를 받아
// Return = 보내기 · Shift+Return = 커서 자리 줄바꿈을 직접 하면 커서가 남는다. ⌘ 등 다른 수정키는 기본 동작(⌘↩ 은 SwiftUI 단축키).
// 화면 키보드의 Return 은 iOS 관례대로 줄바꿈이다(누름 이벤트가 오지 않는다).
// 한글 조합: Return 이 오면 조합 중인 글자를 먼저 확정한 뒤 보낸다(마지막 음절이 빠지거나 보낸 뒤 되살아나지 않게).
import SwiftUI
import UIKit

struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var textColor: UIColor
    var maxLines: Int = 6
    var accessibilityLabel: String
    /// 하드웨어 Return(수정키 없음) — 입력칸의 실제 글(조합 확정 뒤)을 넘긴다.
    let onSubmit: (String) -> Void
    /// 진단 기록 한 줄(글 내용은 넣지 않는다 — 길이만).
    var onKeyNote: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> HandeComposerTextView {
        let view = HandeComposerTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.maxLines = maxLines
        view.textColor = textColor
        view.text = text
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityIdentifier = "composer-input"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.onReturn = { [weak coordinator = context.coordinator] shift in coordinator?.handleReturn(shift: shift) }
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: HandeComposerTextView, context: Context) {
        context.coordinator.parent = self
        view.textColor = textColor
        // 앱이 글을 바꿨다(보낸 뒤 비우기 · 초안 복원 · 붙여넣기 대체). 사용자가 치는 동안은 입력칸 → `text` 가 먼저 같아지므로 여기 오지 않는다.
        // 조합 중이어도 반영한다: 조합 중 전송 버튼·⌘↩ 로 보낸 뒤 비우기를 건너뛰면 보낸 글이 입력칸에 남아 다음 키에 되살아난다(리뷰 #632).
        // 확정·대입 중에 입력칸이 알리는 변경은 `applying` 으로 무시한다 — 방금 비운 `text` 를 옛 글로 덮지 않게.
        if view.text != text {
            context.coordinator.applying = true
            if view.markedTextRange != nil { view.unmarkText() }
            view.text = text
            context.coordinator.applying = false
            view.updateScrolling()
        }
        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async {
                if context.coordinator.parent.isFocused, view.window != nil, !view.isFirstResponder { view.becomeFirstResponder() }
            }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async {
                if !context.coordinator.parent.isFocused, view.isFirstResponder { view.resignFirstResponder() }
            }
        }
    }

    /// 1~`maxLines` 줄 높이(종전 `TextField(axis: .vertical).lineLimit(1...6)` 와 같게). 넘으면 안에서 스크롤.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HandeComposerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let line = ceil(uiView.font?.lineHeight ?? 20)
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(max(fit, line), line * CGFloat(maxLines)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        weak var textView: HandeComposerTextView?
        /// 앱이 글을 넣는 중 — 그동안 오는 변경 알림은 사용자 입력이 아니다.
        var applying = false

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !applying else { return }
            if parent.text != textView.text { parent.text = textView.text }
            (textView as? HandeComposerTextView)?.updateScrolling()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            // 뷰 갱신 도중 상태를 바꾸지 않게 한 박자 뒤.
            DispatchQueue.main.async { if !self.parent.isFocused { self.parent.isFocused = true } }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            DispatchQueue.main.async { if self.parent.isFocused { self.parent.isFocused = false } }
        }


        /// 하드웨어 Return. Shift = 커서 자리 줄바꿈, 아니면 보내기. 조합 중인 글자는 먼저 확정한다.
        func handleReturn(shift: Bool) {
            guard let view = textView else { return }
            let marked = view.markedTextRange != nil
            if marked { view.unmarkText() }
            if shift {
                view.insertText("\n")
                parent.onKeyNote("composer return shift marked=\(marked) len=\(view.text.count) first=\(view.isFirstResponder)")
            } else {
                let current = view.text ?? ""
                parent.onKeyNote("composer return send marked=\(marked) len=\(current.count) first=\(view.isFirstResponder)")
                parent.onSubmit(current)
            }
        }
    }
}

/// 하드웨어 Return 을 입력칸 기본 동작보다 먼저 받는 UITextView.
final class HandeComposerTextView: UITextView {
    var onReturn: ((_ shift: Bool) -> Void)?
    var maxLines = 6

    /// 배치가 바뀔 때마다(첫 배치 · 회전 · 글자 크기) 스크롤 여부를 다시 정한다 — 글이 바뀔 때만 보면 첫 배치 폭 0·회전을 놓친다.
    override func layoutSubviews() {
        super.layoutSubviews()
        updateScrolling()
    }

    /// 최대 줄 수를 넘으면 입력칸 안에서 스크롤(그 전에는 늘어난다). 스크롤을 끌 때는 맨 위로 되돌린다(글이 어긋나 보이지 않게).
    func updateScrolling() {
        guard bounds.width > 0 else { return }
        let line = ceil(font?.lineHeight ?? 20)
        let fit = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        let scroll = fit > line * CGFloat(maxLines) + 1
        guard isScrollEnabled != scroll else { return }
        isScrollEnabled = scroll
        if !scroll { contentOffset = .zero }
    }
    /// 우리가 처리한 Return 누름 — 끝·취소 이벤트도 기본 동작으로 넘기지 않는다(시작만 가로채면 짝이 맞지 않는다).
    private var handled = Set<UIPress>()

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            if let shift = Self.returnShift(press) {
                handled.insert(press)
                onReturn?(shift)
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(handled)
        handled.subtract(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(handled)
        handled.subtract(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    /// 수정키 없는 Return → false(보내기), Shift+Return → true(줄바꿈), 그 밖의 키·수정키 조합 → nil(기본 동작).
    private static func returnShift(_ press: UIPress) -> Bool? {
        guard let key = press.key, key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter else { return nil }
        let modifiers = key.modifierFlags.intersection([.shift, .command, .alternate, .control])
        if modifiers.isEmpty { return false }
        if modifiers == .shift { return true }
        return nil
    }
}
