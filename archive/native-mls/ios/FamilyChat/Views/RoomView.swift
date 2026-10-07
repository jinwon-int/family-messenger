// §9-4 방 화면: `MessageStore` 타임라인 + 작성창. 내 메시지 오른쪽, 상대 왼쪽에 보낸 기기·actor. 봇 배지는 L3 의 actor 판정 뒤.
import SwiftUI
import FamilyMLSCore

struct RoomView: View {
    @EnvironmentObject private var model: AppModel
    let room: RoomID
    @State private var draft = ""
    @State private var messages: [MessageRecord] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages, id: \.seq) { message in
                        MessageRow(message: message, mine: message.senderDevice == model.deviceId)
                    }
                }
                .padding()
            }
            if let error = model.lastError {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            HStack {
                TextField(Strings.composerPlaceholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button(Strings.sendButton) {
                    let text = draft
                    draft = ""
                    Task {
                        // 암호화 전에 실패하면(동기화 실패·정지 등) 입력을 되돌린다 — 평문은 이 화면만 들고 있다.
                        if await model.send(room: room, text: text) == nil, draft.isEmpty { draft = text }
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isReady)
            }
            .padding()
        }
        .navigationTitle(room)
        .onAppear { messages = model.messages(room: room) }
        .onChange(of: model.messagesRevision) { _ in messages = model.messages(room: room) }
    }

    private var isReady: Bool {
        if case .ready = model.phase { return true }
        return false
    }
}

struct MessageRow: View {
    let message: MessageRecord
    let mine: Bool

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if !mine {
                    Text("\(message.senderActor) · \(message.senderDevice)").font(.caption).foregroundStyle(.secondary)
                }
                Text(message.kind == .undecryptable ? Strings.undecryptable : message.body)
                    .padding(10)
                    .background(mine ? Color.accentColor.opacity(0.9) : Color(.secondarySystemBackground))
                    .foregroundStyle(mine ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if !mine { Spacer(minLength: 40) }
        }
    }
}
