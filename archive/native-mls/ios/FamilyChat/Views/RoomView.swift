// §9-4 방 화면: `MessageStore` 타임라인 + 작성창 + 첨부(사진·파일 ≤256 KiB) + 초대(§12-E). 내 메시지 오른쪽, 상대 왼쪽에 보낸 기기·actor. 봇 배지는 L3 의 actor 판정 뒤.
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import FamilyMLSCore

struct RoomView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let room: RoomID
    @State private var draft = ""
    @State private var messages: [AppModel.TimelineItem] = []
    /// #398: 최하단을 따라가는 중인가 — 방 진입·새 메시지 때 켜지고, 사용자가 끌어 올리면 꺼진다.
    @State private var followLatest = true
    @State private var showInvite = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var attachBusy = false
    /// #405 P1: 승인 요청 seq → 상태(허락/거절 버튼을 보일지).
    @State private var approvalStates: [Int64: AgentApproval.State] = [:]
    private static let thinkingRowID: Int64 = -1

    var body: some View {
        VStack(spacing: 0) {
            // #385: 타임라인은 seq 오름차순(오래된 것이 위)이라 기본 ScrollView 는 최상단에서 열린다.
            // 진입 시 최신 메시지(최하단)로 바로 가고, 새 메시지가 붙으면 따라 내려간다.
            ScrollViewReader { proxy in
              VStack(spacing: 0) {
                // #405 P1: "내 마지막 말" 바(웹 last-sent.js) — 에이전트에게 무엇을 시켰는지, 답이 몇 개 왔는지.
                if let last = LastSent.find(messages.map(\.record), myDevice: model.deviceId) {
                    LastSentBar(lastSent: last) {
                        followLatest = false
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.record.seq, anchor: .center) }
                    }
                    Divider()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { item in
                            MessageRow(item: item, mine: item.record.senderDevice == model.deviceId,
                                       roster: model.agentRoster, approval: approvalStates[item.id], canAnswer: isReady,
                                       decide: { number, allow in answerApproval(number, allow: allow) },
                                       onAttachmentLoaded: { attachmentLoaded(item.id, proxy) })
                                .id(item.id)
                        }
                        // #405 P1: 내 글 뒤 에이전트 답이 아직 없으면 "생각하는 중"(앱 추정, 20분 상한 — 15초마다 다시 본다).
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            if let agent = AgentThinking.agent(messages.map(\.record), roster: model.agentRoster,
                                                               myDevice: model.deviceId, now: context.date) {
                                ThinkingRow(name: AgentRoster.displayName(device: agent, names: Strings.agentNames))
                                    .padding(.top, 2)
                            }
                        }
                        .id(Self.thinkingRowID)
                    }
                    .padding()
                }
                // 손가락으로 끌면(위로 읽으러 감) 늦은 이미지 로딩이 화면을 끌어내리지 않게 한다.
                .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in followLatest = false })
                .onAppear {
                    reload()
                    followLatest = true
                    scrollToLatest(proxy, animated: false)
                }
                .onChange(of: model.messagesRevision) { _ in
                    reload()
                    followLatest = true
                    scrollToLatest(proxy, animated: true)
                }
              }
            }
            if let halted = haltedReason {
                HaltedRoomCard(room: room, reason: halted, onForgotten: { dismiss() })
                    .padding()
                    .background(Color.red.opacity(0.15))
            }
            if let error = model.lastError {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
            if attachBusy {
                Text(Strings.attachPreparing).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            HStack {
                // `PhotosPicker` 를 Menu 항목으로 두면 iOS 가 선택 창을 띄우지 않는다(build 13 실기기: 파일은 뜨고 사진은 안 뜸).
                // 메뉴는 플래그만 올리고, 선택 창은 뷰에 붙인 `.photosPicker(isPresented:)` 수정자가 띄운다.
                Menu {
                    Button { showPhotoPicker = true } label: { Label(Strings.attachPhoto, systemImage: "photo") }
                    Button { showFileImporter = true } label: { Label(Strings.attachFile, systemImage: "doc") }
                } label: { Image(systemName: "paperclip") }
                    .accessibilityLabel(Strings.attachMenu)
                    .disabled(!isReady || attachBusy)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showInvite = true } label: { Image(systemName: "person.badge.plus") }
                    .accessibilityLabel(Strings.inviteTitle)
                    .disabled(!model.canRequestJoin)
            }
        }
        .sheet(isPresented: $showInvite) { InviteView(room: room).environmentObject(model) }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhoto, matching: .images)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data]) { result in
            Task { await sendFile(result) }
        }
        .onChange(of: pickedPhoto) { item in
            guard let item else { return }
            pickedPhoto = nil
            Task { await sendPhoto(item) }
        }
    }

    private func reload() {
        messages = model.messages(room: room)
        approvalStates = AgentApproval.states(messages.map(\.record), roster: model.agentRoster)
    }

    /// #405 P1: 승인 카드 버튼 = 봇이 알아듣는 「승인 n」/「거절 n」 글을 대신 보낸다.
    private func answerApproval(_ number: Int, allow: Bool) {
        Task { _ = await model.send(room: room, text: Strings.approvalReply(number, allow: allow)) }
    }

    /// #398: 첨부 본체가 읽혀 행이 커졌다 — 끝 쪽 행이고 따라가는 중이면 최하단을 다시 맞춘다.
    private func attachmentLoaded(_ id: Int64, _ proxy: ScrollViewProxy) {
        guard ScrollFollow.shouldRescroll(loaded: id, ids: messages.map(\.id), following: followLatest) else { return }
        scrollToLatest(proxy, animated: false)
    }

    /// 마지막 메시지(seq 최대)로 스크롤한다. `messages` 를 바꾼 직후라 LazyVStack 이 아직 그 행을 배치하지 않았을 수 있으므로
    /// 한 런루프 뒤에 부른다 — 같은 틱에 부르면 앵커가 없어 조용히 무시된다(iOS 16 대상이라 `defaultScrollAnchor` 는 못 쓴다).
    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        // #405 P1: 맨 끝은 "생각하는 중" 자리(TimelineView, 비어 있으면 높이 0) — 그 줄까지 보이게 거기로 간다.
        guard !messages.isEmpty else { return }
        let last = Self.thinkingRowID
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            } else {
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    private var isReady: Bool {
        if case .ready = model.phase { return true }
        return false
    }

    /// 이 방의 정지 사유(다른 방의 정지는 여기 보이지 않는다 — 전역 배너가 알린다).
    private var haltedReason: String? {
        model.rooms.first { $0.room == room }?.haltedReason
    }

    private func sendPhoto(_ item: PhotosPickerItem) async {
        attachBusy = true
        defer { attachBusy = false }
        guard let raw = try? await item.loadTransferable(type: Data.self) else { model.noteError(Strings.attachPhotoUnreadable); return }
        guard let prepared = AttachmentPreparer.preparePhoto(raw) else { model.noteError(Strings.attachmentTooLarge(raw.count)); return }
        await model.sendAttachment(room: room, data: prepared)
    }

    private func sendFile(_ result: Result<URL, Error>) async {
        attachBusy = true
        defer { attachBusy = false }
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let raw = try? Data(contentsOf: url) else { model.noteError(Strings.attachFileUnreadable); return }
        guard let prepared = AttachmentPreparer.prepareFile(raw) else { model.noteError(Strings.attachmentTooLarge(raw.count)); return }
        await model.sendAttachment(room: room, data: prepared)
    }
}

struct MessageRow: View {
    let item: AppModel.TimelineItem
    let mine: Bool
    /// #405 P1: 에이전트 글이면 카드·승인 카드로 그린다.
    var roster = AgentRoster(actors: [])
    var approval: AgentApproval.State? = nil
    var canAnswer = true
    var decide: (Int, Bool) -> Void = { _, _ in }
    /// #398: 첨부 본체를 읽어 행 높이가 바뀐 뒤 한 번.
    var onAttachmentLoaded: () -> Void = {}
    private var message: MessageRecord { item.record }

    var body: some View {
        if !mine, message.kind == .text, roster.isAgent(message) {
            agentRow
        } else {
            bubbleRow
        }
    }

    @ViewBuilder private var agentRow: some View {
        let name = AgentRoster.displayName(device: message.senderDevice, names: Strings.agentNames)
        if let request = AgentApproval.request(in: message.body) {
            ApprovalCard(name: name, request: request, state: approval ?? .closed, enabled: canAnswer) { allow in
                decide(request.number, allow)
            }
        } else if AgentApproval.resolution(in: message.body) != nil {
            // 처리 결과(「승인 #1: 허용했습니다.」)는 카드 대신 한 줄 — 위 승인 카드가 이미 결과를 보여 준다.
            HStack(spacing: 6) {
                Circle().fill(AgentPalette.accent).frame(width: 6, height: 6)
                Text(message.body).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            AgentMessageCard(name: name, text: message.body)
        }
    }

    private var bubbleRow: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if !mine {
                    Text("\(message.senderActor) · \(message.senderDevice)").font(.caption).foregroundStyle(.secondary)
                }
                content
                    .padding(10)
                    .background(mine ? Color.accentColor.opacity(0.9) : Color(.secondarySystemBackground))
                    .foregroundStyle(mine ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if !mine { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .attachment:
            AttachmentBubble(item: item, onLoaded: onAttachmentLoaded)
        case .undecryptable:
            Text(Strings.undecryptable)
        default:
            Text(message.body)
        }
    }
}

/// 첨부 말풍선: 본체는 보일 때 한 번 읽는다(#364 지연 로딩). 이미지는 미리보기(긴 변 ≤220pt), 그 밖은 종류·크기. 둘 다 저장·공유(ShareLink → 임시 파일).
struct AttachmentBubble: View {
    @EnvironmentObject private var model: AppModel
    let item: AppModel.TimelineItem
    var onLoaded: () -> Void = {}
    @State private var data: Data?

    private var message: MessageRecord { item.record }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let data, AttachmentFormat.isImage(mime: message.body), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(Strings.attachmentImage)
            } else if data == nil {
                Text(Strings.attachmentLoading(item.attachmentBytes)).font(.footnote)
            } else {
                Text(Strings.attachmentFile(item.attachmentBytes, message.body)).font(.footnote)
            }
            if let data, let url = AttachmentExport.temporaryURL(for: message, bytes: data) {
                ShareLink(item: url) { Label(Strings.attachmentSave, systemImage: "square.and.arrow.up") }.font(.caption)
            }
        }
        .task(id: message.seq) {
            guard data == nil else { return }
            data = model.attachment(room: message.room, seq: message.seq)
            if data != nil { onLoaded() }
        }
    }
}
