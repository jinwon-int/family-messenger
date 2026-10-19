// §9-4 방 화면: `MessageStore` 타임라인 + 작성창 + 첨부(사진·파일 ≤256 KiB) + 초대(§12-E). 내 메시지 오른쪽, 상대 왼쪽에 보낸 기기·actor. 봇 배지는 L3 의 actor 판정 뒤.
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import FamilyMLSCore

struct RoomView: View {
    @EnvironmentObject private var model: AppModel
    /// #405 P3: 방 전환·목록 복귀(단축키) · 이 기기 읽음 표시.
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var prefs: LocalPrefs
    @FocusState private var composerFocused: Bool
    /// iOS 16 `onChange` 는 새 값만 준다 — 줄바꿈 하나가 막 들어왔는지 보려고 직전 글을 쥔다.
    @State private var previousDraft = ""
    @Environment(\.dismiss) private var dismiss
    let room: RoomID
    @State private var draft = ""
    @State private var messages: [AppModel.TimelineItem] = []
    /// #398: 최하단을 따라가는 중인가 — 방 진입·새 메시지 때 켜지고, 사용자가 끌어 올리면 꺼진다.
    @State private var followLatest = true
    /// 메시지 칸의 마지막 높이(키보드·작성창 높이 변화 감지용, `ScrollFollow.shouldRescrollOnResize`).
    @State private var viewportHeight: Double = 0
    /// 목록 내용의 마지막 높이(진입 직후 실제 배치·이미지 로딩으로 커지면 다시 최하단, `ScrollFollow.shouldRescrollOnContentGrowth`).
    @State private var contentHeight: Double = 0
    @State private var showInvite = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var attachBusy = false
    /// #405 P1: 승인 요청 seq → 상태(허락/거절 버튼을 보일지).
    @State private var approvalStates: [Int64: AgentApproval.State] = [:]
    /// #405 시간 표시: 행별 시간 보임 여부 · 날짜 구분선.
    @State private var stamps: [Int64: TimelineStamps.Stamp] = [:]
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
                            if let day = stamps[item.id]?.dayStart {
                                DayDivider(text: Strings.dayLabel(day))
                            }
                            MessageRow(item: item, mine: item.record.senderDevice == model.deviceId,
                                       time: stamps[item.id]?.showTime == true ? item.record.receivedAt : nil,
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
                    // 내용이 커지면(lazy 행의 실제 배치·이미지 로딩·구분선) 따라가는 중일 때 최하단을 다시 맞춘다 — 진입 시 2~3번째 최신 글에서 멈추던 결함.
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: Double(geo.size.height))
                    })
                }
                .onPreferenceChange(ContentHeightKey.self) { height in
                    let old = contentHeight
                    contentHeight = height
                    if ScrollFollow.shouldRescrollOnContentGrowth(old: old, new: height, following: followLatest) {
                        scrollToLatest(proxy, animated: false)
                    }
                }
                // 손가락으로 끌면(위로 읽으러 감) 늦은 이미지 로딩이 화면을 끌어내리지 않게 한다.
                .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in followLatest = false })
                // 키보드가 올라오거나 작성창이 커져 칸이 줄면 최신 메시지를 키보드 바로 위로 다시 맞춘다.
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ViewportHeightKey.self, value: Double(geo.size.height))
                })
                .onPreferenceChange(ViewportHeightKey.self) { height in
                    let old = viewportHeight
                    viewportHeight = height
                    if ScrollFollow.shouldRescrollOnResize(old: old, new: height, following: followLatest) {
                        scrollToLatest(proxy, animated: true)
                    }
                }
                // 쓰려고 작성창을 누르면 = 최신 대화에 답하는 중: 따라가기를 다시 켜고 최하단으로 간다(하드웨어 키보드는 칸이 안 줄어 여기서만 맞춘다).
                .onChange(of: composerFocused) { focused in
                    guard focused else { return }
                    followLatest = true
                    scrollToLatest(proxy, animated: true)
                }
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
                // 긴 오류가 대화를 가리지 않게 두 줄까지만(연결 끊김은 여기 오지 않고 제목 아래 「연결 중입니다…」).
                Text(error).font(.footnote).foregroundStyle(.red).lineLimit(2).padding(.horizontal)
            }
            if attachBusy {
                Text(Strings.attachPreparing).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            // #405 P3: 에이전트가 있는 방이면 자주 쓰는 말 칩 — 누르면 작성창에 채운다(바로 보내지 않는다).
            if glance.hasAgent && isReady {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Strings.quickSay, id: \.self) { phrase in
                            Button { draft = phrase; composerFocused = true } label: {
                                Text(phrase.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":")))
                                    .font(.caption)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Hande.agent.opacity(0.12)))
                                    .overlay(Capsule().stroke(Hande.agent.opacity(0.3), lineWidth: 1))
                                    .foregroundStyle(Hande.agent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 4)
            }
            HStack(spacing: 10) {
                // `PhotosPicker` 를 Menu 항목으로 두면 iOS 가 선택 창을 띄우지 않는다(build 13 실기기: 파일은 뜨고 사진은 안 뜸).
                // 메뉴는 플래그만 올리고, 선택 창은 뷰에 붙인 `.photosPicker(isPresented:)` 수정자가 띄운다.
                Menu {
                    Button { showPhotoPicker = true } label: { Label(Strings.attachPhoto, systemImage: "photo") }
                    Button { showFileImporter = true } label: { Label(Strings.attachFile, systemImage: "doc") }
                } label: { Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(Hande.ember) }
                    .accessibilityLabel(Strings.attachMenu)
                    .disabled(!isReady || attachBusy)
                // #405 P2: 불가 자리 — 둥근 입력칸 + 불빛 원형 전송 버튼.
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    // #405 P3: 하드웨어 키보드 Enter = 전송, Shift+Enter = 줄바꿈(웹 keyboard.js). 화면 키보드는 줄바꿈 그대로.
                    .onChange(of: draft) { new in
                        let old = previousDraft
                        previousDraft = new
                        switch ComposerKeys.decide(old: old, new: new, hardwareKeyboard: HardwareKeyboard.isConnected,
                                                   shift: HardwareKeyboard.isShiftPressed) {
                        case .keep: break
                        case .revert(let text): draft = text
                        case .send(let text): sendText(text)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Hande.surface))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Hande.ember.opacity(0.28), lineWidth: 1))
                Button {
                    sendText(draft)
                } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(Hande.onEmber)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend ? Hande.ember : Hande.ember.opacity(0.35)))
                }
                .accessibilityLabel(Strings.sendButton)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(LinearGradient(colors: [Hande.glow.opacity(0.0), Hande.glow.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }
        .background(CampfireBackground())
        .background(keyboardShortcuts)
        .navigationTitle(room)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // #405 P2: 제목 아래 불가에 둘러앉은 자리(사람 크림색 · 에이전트 파란색).
            ToolbarItem(placement: .principal) {
                VStack(spacing: 3) {
                    Text(room).font(.headline).foregroundStyle(Hande.ink)
                    SeatDots(people: glance.people.count, agents: glance.agents.count, size: 6)
                    // 릴레이에 닿지 않는 동안만(원문 오류 대신). 동기화가 한 번 성공하면 사라진다.
                    if model.reconnecting {
                        Text(Strings.connecting).font(.caption2).foregroundStyle(Hande.inkDim)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: model.reconnecting)
            }
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

    /// #405 P2: 이 방의 자리 요약(제목 아래 점 · 작성창 안내).
    private var glance: RoomGlance { RoomGlance.make(messages.map(\.record), roster: model.agentRoster) }

    private var placeholder: String {
        guard let agent = glance.agents.last else { return Strings.composerPlaceholder }
        return Strings.composerPlaceholderAgent(AgentRoster.displayName(device: agent, names: Strings.agentNames))
    }

    private func reload() {
        messages = model.messages(room: room)
        // #405 P3: 이 방을 보고 있다 = 마지막 글까지 읽음(이 기기에만).
        if let last = messages.last { prefs.markRead(room, seq: last.id) }
        approvalStates = AgentApproval.states(messages.map(\.record), roster: model.agentRoster)
        stamps = TimelineStamps.compute(messages.map(\.record), calendar: .current)
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

    /// 작성창 글을 보낸다. 암호화 전에 실패하면(동기화 실패·정지 등) 입력을 되돌린다 — 평문은 이 화면만 들고 있다.
    private func sendText(_ text: String) {
        guard isReady, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        previousDraft = ""
        draft = ""
        Task {
            if await model.send(room: room, text: text) == nil, draft.isEmpty { draft = text }
        }
    }

    /// #405 P3 하드웨어 키보드 단축키(웹 keyboard.js 차용, iPad 에서 ⌘ 를 누르고 있으면 목록이 보인다):
    /// ⌘↩ 보내기 · Esc 작성창 닫기(대화 읽기) · PageUp/PageDown 이전·다음 대화방 · Home 대화 목록.
    private var keyboardShortcuts: some View {
        ZStack {
            Button(Strings.sendButton) { sendText(draft) }.keyboardShortcut(.return, modifiers: .command)
            Button(Strings.shortcutReadTimeline) { composerFocused = false }.keyboardShortcut(.escape, modifiers: [])
            Button(Strings.shortcutPreviousRoom) { switchRoom(-1) }.keyboardShortcut(.pageUp, modifiers: [])
            Button(Strings.shortcutNextRoom) { switchRoom(1) }.keyboardShortcut(.pageDown, modifiers: [])
            Button(Strings.shortcutRoomList) { navigator.backToList() }.keyboardShortcut(.home, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func switchRoom(_ step: Int) {
        let ids = RoomOrder.apply(model.listedRooms, saved: prefs.roomOrder).map(\.room)
        if let next = RoomOrder.neighbor(of: room, in: ids, step: step) { navigator.open(next) }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isReady }

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
    /// #405 시간 표시: 묶음의 마지막 행만 시각을 받는다(nil = 숨김).
    var time: Date? = nil
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
            ApprovalCard(name: name, request: request, state: approval ?? .closed, enabled: canAnswer, time: time) { allow in
                decide(request.number, allow)
            }
        } else if AgentApproval.resolution(in: message.body) != nil {
            // 처리 결과(「승인 #1: 허용했습니다.」)는 카드 대신 한 줄 — 위 승인 카드가 이미 결과를 보여 준다.
            HStack(spacing: 6) {
                Circle().fill(AgentPalette.accent).frame(width: 6, height: 6)
                Text(message.body).font(.caption).foregroundStyle(.secondary)
                if let time { Text("· \(Strings.messageTime(time))").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            AgentMessageCard(name: name, text: message.body, time: time)
        }
    }

    @ViewBuilder private var timeLabel: some View {
        if let time {
            Text(Strings.messageTime(time)).font(.caption2).foregroundStyle(Hande.inkDim).fixedSize()
        }
    }

    private var bubbleRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if mine { Spacer(minLength: 40); timeLabel }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if !mine {
                    // #405 P2: 기기 ID 대신 이름 · 기기 종류(오너 · PC).
                    Text(Strings.senderLabel(device: message.senderDevice)).font(.caption).foregroundStyle(Hande.inkDim)
                        .padding(.leading, 4)
                }
                content
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(mine ? AnyShapeStyle(Hande.emberDeep) : AnyShapeStyle(Hande.surface))
                    .foregroundStyle(mine ? Hande.onEmber : Hande.ink)
                    .clipShape(BubbleShape(mine: mine))
            }
            if !mine { timeLabel; Spacer(minLength: 40) }
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
    /// 사진 탭 → 전체 화면 보기(오너 요청 build 30).
    @State private var showViewer = false

    private var message: MessageRecord { item.record }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let data, AttachmentFormat.isImage(mime: message.body), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { showViewer = true }
                    .accessibilityLabel(Strings.attachmentImage)
                    .accessibilityAddTraits(.isButton)
                    .fullScreenCover(isPresented: $showViewer) {
                        ImageViewer(image: image, shareURL: AttachmentExport.temporaryURL(for: message, bytes: data))
                    }
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

/// 전체 화면 사진 보기: 검은 바탕 · 핀치 확대(1~4배) · 두 번 탭으로 2배/원래 크기 · 닫기 · 저장·공유.
struct ImageViewer: View {
    let image: UIImage
    let shareURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: UIScreen.main.bounds.width * scale, height: UIScreen.main.bounds.height * scale)
            }
            .ignoresSafeArea()
            .gesture(
                MagnificationGesture()
                    .onChanged { value in scale = min(max(lastScale * value, 1), 4) }
                    .onEnded { _ in lastScale = scale }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { scale = scale > 1 ? 1 : 2 }
                lastScale = scale
            }
            HStack(spacing: 14) {
                if let shareURL {
                    ShareLink(item: shareURL) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(Strings.attachmentSave)
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Strings.attachmentViewerClose)
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding(14)
            .background(Circle().fill(.clear))
        }
        .accessibilityHint(Strings.attachmentViewerHint)
        .preferredColorScheme(.dark)
    }
}

/// #405 P2: 말풍선 — 말한 쪽 아래 모서리만 덜 둥글다(꼬리 자리).
struct BubbleShape: Shape {
    let mine: Bool
    /// iOS 16 대상이라 `UnevenRoundedRectangle`(17+) 대신 직접 그린다.
    func path(in rect: CGRect) -> Path {
        let big = min(18, rect.height / 2, rect.width / 2), small = min(5, big)
        let tl = big, tr = big, bl = mine ? big : small, br = mine ? small : big
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// #405 시간 표시: 날짜가 바뀌는 자리의 구분선(오늘 · 어제 · 10월 18일 토요일).
struct DayDivider: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Hande.stroke).frame(height: 1)
            Text(text).font(.caption2.weight(.semibold)).foregroundStyle(Hande.inkDim).fixedSize()
            Rectangle().fill(Hande.stroke).frame(height: 1)
        }
        .padding(.vertical, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 메시지 칸(ScrollView 바깥 틀)의 높이를 RoomView 로 올린다.
struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = nextValue() }
}

/// 목록 내용(LazyVStack)의 높이를 RoomView 로 올린다.
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = nextValue() }
}
