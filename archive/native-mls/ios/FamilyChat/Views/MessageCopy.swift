// 말풍선 글 복사(오너 요청 2026-10-30, 「2」): 꾹 누르기 메뉴 「복사」(글 전체) + 「선택해서 복사」(읽기 전용 글 창에서 일부만 골라 복사).
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
            return record.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : record.body
        case .attachment, .fileV2, .undecryptable:
            return nil
        }
    }

    @MainActor static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

/// 「선택해서 복사」 시트에 넘기는 글(시트 `item:` 용).
struct SelectableMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// 하드웨어 키보드 선택 모드(Enter)로 열었다 — 창이 뜨면 글에 커서를 둬 Shift+방향키 선택 · ⌘C 복사를 바로 쓸 수 있게.
    var fromKeyboard = false
}

/// 꾹 누르기 메뉴: 「복사」 · 「선택해서 복사」. 복사할 글이 없으면(첨부 등) 메뉴를 붙이지 않는다.
struct MessageCopyMenu: ViewModifier {
    let text: String?
    let select: (String) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if let text {
            content
                .contextMenu {
                    Button { MessageCopy.copy(text) } label: { Label(Strings.messageCopy, systemImage: "doc.on.doc") }
                    Button { select(text) } label: { Label(Strings.messageSelectCopy, systemImage: "selection.pin.in.out") }
                }
        } else {
            content
        }
    }
}

extension View {
    func messageCopyMenu(_ text: String?, select: @escaping (String) -> Void) -> some View {
        modifier(MessageCopyMenu(text: text, select: select))
    }
}

/// 「선택해서 복사」 창: 글을 읽기 전용으로 띄워 손가락으로 범위를 골라 iOS 기본 메뉴로 복사한다. 「전체 복사」는 바로 복사하고 닫는다.
struct SelectableTextSheet: View {
    let text: String
    var focusText = false
    @Environment(\.dismiss) private var dismiss

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
        .presentationDetents([.medium, .large])
        // 하드웨어 키보드 Esc = 닫기(글 칸이 Esc 를 먼저 쓰면 SwiftUI 단축키가 닿지 않아 GameController 길로도 받는다).
        .onReceive(HardwareKeyRouter.shared.presses) { press in
            if press == HardwareKeys.Press(.escape) { dismiss() }
        }
    }
}

/// 읽기 전용·선택 가능한 UITextView(편집 불가, 링크 자동 감지 없음 — 받은 글은 신뢰하지 않는다).
struct SelectableTextView: UIViewRepresentable {
    let text: String
    var focusOnAppear = false

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        view.text = text
        if focusOnAppear {
            // 시트가 다 올라온 뒤 글 맨 앞에 커서 — 키보드로 바로 범위를 고른다(편집 불가라 글은 바뀌지 않는다).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if view.becomeFirstResponder() { view.selectedRange = NSRange(location: 0, length: 0) }
            }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
