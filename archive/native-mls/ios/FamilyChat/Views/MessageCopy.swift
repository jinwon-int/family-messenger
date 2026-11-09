// 말풍선 글 복사(오너 요청 2026-10-30, 「2」): 꾹 누르기 메뉴 「복사」(글 전체) + 「선택해서 복사」(읽기 전용 글 창에서 일부만 골라 복사).
// 공유·답장(오너 요청 2026-11-09): 「공유」= iOS 공유 시트(글만) · 「답장」= 작성창 위 답장 띠 → 본문 앞 인용 한 줄(FamilyMLSCore `ReplyQuote`).
// SwiftUI `.textSelection(.enabled)` 는 iOS 에서 범위 선택이 안 되고(글 전체 복사만) 메뉴도 정할 수 없어서, 범위 선택은 UITextView 로 한다.
// 첨부(설명자·파일 키)·복호화 실패 행은 복사 대상이 아니다 — 글로 보이거나 공유하지 않는다(#499 원칙).
import SwiftUI
import UIKit
import FamilyMLSCore

enum MessageCopy {
    /// 복사할 글. 사람·에이전트·서비스 봇의 글(.text)과 시스템 줄(.system)만 — 첨부·복호화 실패·빈 글은 nil(메뉴 없음).
    static func text(of record: MessageRecord) -> String? {
        switch record.kind {
        case .text, .system:
            // 답장 글(ReplyQuote)은 인용 머리를 빼고 내 글만 — 복사·공유·답장 요약 모두 보이는 본문 기준.
            let body = ReplyQuote.visibleText(record.body)
            return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body
        case .attachment, .fileV2, .undecryptable:
            return nil
        }
    }

    @MainActor static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// 붙여넣을 글(대화 읽기·선택 모드 ⌘V).
    @MainActor static var clipboardText: String? {
        UIPasteboard.general.string
    }
}

/// 「선택해서 복사」 시트에 넘기는 글(시트 `item:` 용).
struct SelectableMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// 하드웨어 키보드 선택 모드(Enter)로 열었다 — 창이 뜨면 글에 커서를 둬 Shift+방향키 선택 · ⌘C 복사를 바로 쓸 수 있게.
    var fromKeyboard = false
}

/// 답장 대상(작성창 위 「OO에게 답장」 띠). 보낼 때 `ReplyQuote.compose` 로 본문 앞에 인용 한 줄을 붙인다.
struct ReplyTarget: Equatable {
    /// 답할 글을 쓴 사람(에이전트·서비스 봇 이름 포함).
    let name: String
    /// 답할 글의 릴레이 seq(v2 `#번호`). 보내는 중인 글(음수 seq)은 nil.
    var seq: Int64? = nil
    /// 답할 글(보이는 본문 — 인용 머리 뺀 것).
    let original: String
    var snippet: String { ReplyQuote.snippet(of: original) }
}

/// 꾹 누르기 메뉴: 「답장」 · 「복사」 · 「선택해서 복사」 · 「공유」. 복사할 글이 없으면(첨부 등) 메뉴를 붙이지 않는다.
/// 「답장」은 보낼 수 있는 방에서만(`reply` nil = 항목 없음). 「공유」는 iOS 공유 시트로 글만 — 첨부·설명자는 대상이 아니다(#499).
struct MessageCopyMenu: ViewModifier {
    let text: String?
    let select: (String) -> Void
    var reply: (() -> Void)? = nil

    @ViewBuilder func body(content: Content) -> some View {
        if let text {
            content
                .contextMenu {
                    if let reply {
                        Button(action: reply) { Label(Strings.messageReply, systemImage: "arrowshape.turn.up.left") }
                    }
                    Button { MessageCopy.copy(text) } label: { Label(Strings.messageCopy, systemImage: "doc.on.doc") }
                    Button { select(text) } label: { Label(Strings.messageSelectCopy, systemImage: "selection.pin.in.out") }
                    ShareLink(item: text) { Label(Strings.messageShare, systemImage: "square.and.arrow.up") }
                }
        } else {
            content
        }
    }
}

extension View {
    func messageCopyMenu(_ text: String?, select: @escaping (String) -> Void, reply: (() -> Void)? = nil) -> some View {
        modifier(MessageCopyMenu(text: text, select: select, reply: reply))
    }
}

/// 답장 글 말풍선 안의 인용 상자: 왼쪽 세로 선 + 이름(굵게) + 원문 요약(세 줄까지). 색은 말풍선 글자색을 한 단계 흐리게.
/// `#번호`는 화면에 쓰지 않는다 — 번호가 있으면 상자를 눌러 그 글로 간다(`open`).
struct ReplyQuoteBox: View {
    let parsed: ReplyQuote.Parsed
    var open: ((Int64) -> Void)? = nil

    var body: some View {
        let box = HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5).fill(.secondary).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if let name = parsed.name { Text(name).font(.footnote.weight(.semibold)) }
                Text(parsed.snippet).font(.footnote).lineLimit(3).multilineTextAlignment(.leading)
            }
            .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.replyQuoteLabel([parsed.name, parsed.snippet].compactMap { $0 }.joined(separator: ": ")))
        if let seq = parsed.seq, let open {
            box.contentShape(Rectangle())
                .onTapGesture { open(seq) }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Strings.replyQuoteOpenHint)
        } else {
            box
        }
    }
}

/// 「선택해서 복사」 창: 글을 읽기 전용으로 띄워 손가락으로 범위를 골라 iOS 기본 메뉴로 복사한다. 「전체 복사」는 바로 복사하고 닫는다.
struct SelectableTextSheet: View {
    let text: String
    var focusText = false
    /// 진단 기록 한 줄(글 내용 없음 — 길이만).
    var onKeyNote: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    /// 「복사했어요」(⌘C 로 블록 복사).
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text, focusOnAppear: focusText)
                .padding(.horizontal, 12)
                .navigationTitle(Strings.messageSelectCopy)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Strings.close) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Strings.messageCopyAll) {
                            MessageCopy.copy(text)
                            dismiss()
                        }
                    }
                }
        }
        .handeToast($toast)
        .presentationDetents([.medium, .large])
        // 하드웨어 키보드 Esc = 닫기(글 칸이 Esc 를 먼저 쓰면 SwiftUI 단축키가 닿지 않아 GameController 길로도 받는다).
        .onReceive(HardwareKeyRouter.shared.presses) { press in
            // 한 박자 늦게 닫는다: 같은 Esc 를 대화방도 받는데, 창이 아직 열려 있어야 대화방이 「창 열림」으로 무시한다(선택 모드 유지).
            if press.key == .letterC || press.key == .escape {
                onKeyNote("sheet \(press.key.rawValue) mods=\(press.modifiers.rawValue) focusText=\(focusText) input=\(FirstResponderText.isActive) "
                          + "selected=\(FirstResponderText.selectedText?.count ?? -1)")
            }
            if press == HardwareKeys.Press(.escape) { DispatchQueue.main.async { dismiss() } }
            // ⌘C: Shift+방향키로 잡은 블록을 복사한다(iOS 기본 복사가 이 창에서 안 먹는 경우에도). 잡은 것이 없으면 그대로 둔다.
            // 키보드로 연 창만(글에 커서가 있다) — 손가락으로 연 창이면 첫 응답자가 뒤쪽 작성창일 수 있다.
            if focusText, press == HardwareKeys.Press(.letterC, .command), let text = FirstResponderText.selectedText {
                MessageCopy.copy(text)
                toast = Strings.notifyCopied
            }
        }
    }
}

/// 읽기 전용·선택 가능한 UITextView(편집 불가, 링크 자동 감지 없음 — 받은 글은 신뢰하지 않는다).
struct SelectableTextView: UIViewRepresentable {
    let text: String
    var focusOnAppear = false

    func makeUIView(context: Context) -> UITextView {
        // 키보드로 연 창(선택 모드 Enter)은 「편집 가능하지만 바뀌지 않는」 글 칸: iOS 는 편집 불가 UITextView 에서 하드웨어 키보드
        // 방향키·Shift+방향키 커서·블록 선택을 하지 않는다(오너 실기기 0.1.0 (77): 창은 열리는데 Shift+방향키로 블록이 안 잡힘).
        // 손가락으로 연 창은 종전대로 편집 불가(화면 키보드·커서 없이 손가락 선택).
        let view: UITextView = focusOnAppear ? KeyboardSelectableTextView() : UITextView()
        view.isEditable = focusOnAppear
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        view.text = text
        if focusOnAppear {
            // 시트가 다 올라온 뒤 글 맨 앞에 커서 — 키보드로 바로 범위를 고른다(글은 바뀌지 않는다).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if view.becomeFirstResponder() { view.selectedRange = NSRange(location: 0, length: 0) }
            }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }   // text 대입은 입력 경로(replace·delegate)를 거치지 않는다
    }
}

/// 하드웨어 키보드로 커서를 움직이고 블록을 잡을 수 있지만 글은 바뀌지 않는 UITextView(받은 글은 고치지 않는다).
/// 편집 가능 상태라야 iOS 가 방향키·Shift+방향키·⌘A 를 처리하므로 `isEditable = true` 로 두고, 글이 바뀌는 길을 모두 막는다:
/// 입력·지우기·조합·바꾸기는 무시, 메뉴는 복사·선택·전체 선택만, 화면 키보드는 띄우지 않는다(빈 입력 뷰).
final class KeyboardSelectableTextView: UITextView, UITextViewDelegate {

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        inputView = UIView()                       // 화면 키보드 없음(하드웨어 키보드는 그대로)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        delegate = self                            // 마지막 방어선: 어떤 바꾸기 요청도 거절
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func insertText(_ text: String) {}
    override func deleteBackward() {}
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    override func replace(_ range: UITextRange, withText text: String) {}

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool { false }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let allowed: [Selector] = [
            #selector(UIResponderStandardEditActions.copy(_:)),
            #selector(UIResponderStandardEditActions.select(_:)),
            #selector(UIResponderStandardEditActions.selectAll(_:)),
        ]
        return allowed.contains(action) && super.canPerformAction(action, withSender: sender)
    }
}
