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
    /// 최하단 표지(높이 1pt, 항상 있음) — 진입·새 메시지·내용 증가 때의 스크롤 목표. 「생각하는 중」 줄은 에이전트가 바로 답하는 방
    /// (family-acc)에서는 높이 0이라 그 줄을 목표로 삼으면 끝까지 가지 않았다(오너 보고 build 31: family 는 되고 family-acc 는 2~3번째).
    private static let bottomSentinelID: Int64 = -2
    /// #472: 맨 위 표지(높이 1pt) — 위로 끌어 올려 이 표지가 가까워지면 과거 글을 한 페이지 더 읽어 위에 붙인다.
    private static let topSentinelID: Int64 = -3
    /// 과거 글을 붙이는 중(한 번에 한 페이지 — 표지 측정이 연달아 와도 중복 읽기 없음).
    @State private var olderBusy = false
    /// #497: 위로 읽는 동안 아래에 새 글이 왔다 — 「새 메시지」 버튼(누르면 최하단).
    @State private var hasNewBelow = false
    /// #497: 프레임마다 바뀌는 실측·스크롤 명령 합치기(참조 상자 — 바꿔도 body 를 다시 그리지 않는다).
    @State private var tracking = ScrollTracking()
    /// 꼬리(lazy 아님)가 시작하는 index · 그 첫 행의 id. LazyVStack 은 화면 밖 행을 만들지 않아, 긴 마지막 글 아래의 바닥 표지가 생성되지
    /// 않으면 측정 보정이 돌지 않고 `scrollTo` 는 추정 위치에 멈춘다(오너 보고 build 33) — 꼬리는 항상 실제 높이라 표지 측정과 `scrollTo` 가
    /// 정확하다. 경계는 **행 id 로 고정**(`TimelineTail`): 종전 "마지막 3행"은 새 글마다 행이 LazyVStack 으로 이사해 추정치가 흔들렸다.
    @State private var tailStart = 0
    @State private var tailAnchor: Int64?

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
                    VStack(alignment: .leading, spacing: 8) {
                        // #472: 맨 위 표지의 **실제** 위치 — 위로 읽으러 올라와 표지가 가까워지면 과거 글을 더 읽는다(onAppear 는 삽입 때 한 번만
                        // 불려 쓸 수 없다; 바닥 표지와 같은 preference 실측).
                        Color.clear.frame(height: 1).id(Self.topSentinelID)
                            .background(GeometryReader { geo in
                                Measured(value: Double(geo.frame(in: .named("timeline")).maxY)) { topSentinelChanged($0, proxy) }
                            })
                        // 오래된 글은 lazy(화면에 보일 때 만든다).
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(messages.prefix(tailStart)) { item in
                                // 2차 계측: 손을 댄 직후 lazy 행이 새로 만들어지면(=새 측정 → 추정치 변동) 그 사실을 남긴다.
                                Group { row(item, proxy) }
                                    .onAppear {
                                        let sinceDrag = Date().timeIntervalSince(tracking.lastDrag)
                                        if sinceDrag < 3 { model.noteScroll("\(room) lazy-appear \(item.id) sinceDrag=\(Int(sinceDrag * 1000))ms") }
                                    }
                            }
                        }
                        // 꼬리는 lazy 가 아니다: 최근 행·「생각하는 중」·바닥 표지가 항상 실제 높이로 존재해야 `scrollTo` 와 표지 측정이 정확하다.
                        // 새 글은 늘 여기에 붙는다(경계 고정 — `TimelineTail`).
                        ForEach(messages.dropFirst(tailStart)) { item in row(item, proxy) }
                        // #405 P1: 내 글 뒤 에이전트 답이 아직 없으면 "생각하는 중"(앱 추정, 20분 상한 — 15초마다 다시 본다).
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            if let agent = AgentThinking.agent(messages.map(\.record), roster: model.agentRoster,
                                                               myDevice: model.deviceId, now: context.date) {
                                ThinkingRow(name: AgentRoster.displayName(device: agent, names: Strings.agentNames))
                                    .padding(.top, 2)
                            }
                        }
                        .id(Self.thinkingRowID)
                        Color.clear.frame(height: 1).id(Self.bottomSentinelID)
                            // 표지의 **실제** 위치(스크롤 뷰 좌표) — 배치가 끝난 뒤 표지가 화면 아래에 남아 있으면 한 번 더 맞춘다.
                            .background(GeometryReader { geo in
                                Measured(value: Double(geo.frame(in: .named("timeline")).maxY)) { bottomSentinelChanged($0, proxy) }
                            })
                    }
                    .padding()
                    // 내용이 커지면(lazy 행의 실제 배치·이미지 로딩·구분선) 따라가는 중일 때 최하단을 다시 맞춘다.
                    .background(GeometryReader { geo in
                        Measured(value: Double(geo.size.height)) { contentHeightChanged($0, proxy) }
                    })
                }
                .coordinateSpace(name: "timeline")
                // #497 A4(오너 build 51 기록으로 확정: 손을 댄 순간 앱의 스크롤 명령 없이 화면이 위로 밀림 = LazyVStack 의 미배치 행이
                // 실체화·재추정되며 내용 높이가 바뀌는데 스크롤 위치가 **위 기준**이라 보이는 행이 밀린다). 바닥 기준으로 바꾼다 —
                // 내용·칸 크기가 바뀌어도 바닥과의 거리를 유지하므로 위쪽 추정치가 아무리 바뀌어도 보이는 행은 그대로. iOS 16 은 종전대로.
                .modifier(BottomAnchoredTimeline())
                // 방을 나가면 창을 기본(최신 `timelineLimit` 건)으로 되돌린다 — 폴링마다 큰 창을 읽지 않는다.
                // #497: 사진 전체 화면 보기가 떠서 불린 경우는 나간 것이 아니다(닫으면 보던 자리 그대로).
                .onDisappear {
                    guard !PhotoViewerPresence.active else { return }
                    model.resetTimelineWindow(room: room)
                }
                // 손가락으로 끌면(위로 읽으러 감) 늦은 이미지 로딩이 화면을 끌어내리지 않게 한다.
                // #497: 손을 떼고 맨 아래에 멈추면 다시 따라간다(`ScrollFollow.shouldRefollow`).
                .simultaneousGesture(DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        // 2차 계측: 끌기 시작 시점의 자리(그 뒤 높이 변화·표지 이동과 비교).
                        if Date().timeIntervalSince(tracking.lastDrag) > 0.5 {
                            model.noteScroll("\(room) drag-start dy=\(Self.pt(value.translation.height)) sentinel=\(Self.pt(tracking.sentinelBottom)) "
                                             + "content=\(Self.pt(contentHeight)) viewport=\(Self.pt(viewportHeight)) following=\(followLatest)")
                        }
                        tracking.lastDrag = Date()
                        if followLatest { followLatest = false }
                    }
                    .onEnded { value in
                        model.noteScroll("\(room) drag-end dy=\(Self.pt(value.translation.height)) sentinel=\(Self.pt(tracking.sentinelBottom)) content=\(Self.pt(contentHeight))")
                        tracking.lastDrag = Date()
                        DispatchQueue.main.asyncAfter(deadline: .now() + ScrollFollow.settleDelay + 0.1) { refollowIfSettledAtBottom() }
                    })
                // #497: 위로 읽는 중에 새 글이 왔다 — 화면은 그대로 두고 버튼으로 알린다.
                .overlay(alignment: .bottom) {
                    if hasNewBelow {
                        Button {
                            followLatest = true
                            hasNewBelow = false
                            scrollToLatest(proxy, animated: true)
                        } label: {
                            Label(Strings.newMessagesBelow, systemImage: "arrow.down")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(Hande.ember))
                                .foregroundStyle(Hande.onEmber)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                    }
                }
                // 키보드가 올라오거나 작성창이 커져 칸이 줄면 최신 메시지를 키보드 바로 위로 다시 맞춘다.
                // build 51 오너 기록: 모든 scroll 줄이 `viewport=0` — PreferenceKey 경로로는 칸 높이가 한 번도 오지 않아 실측 보정 4종
                // (`needsBottomCorrection`·`isPastContentEnd`·`shouldRefollow`·키보드)이 전부 죽어 있었다. GeometryReader 가 잰 값을 바로 보고한다.
                .background(GeometryReader { geo in
                    Measured(value: Double(geo.size.height)) { viewportChanged($0, proxy) }
                })
                // 쓰려고 작성창을 누르면 = 최신 대화에 답하는 중: 따라가기를 다시 켜고 최하단으로 간다(하드웨어 키보드는 칸이 안 줄어 여기서만 맞춘다).
                .onChange(of: composerFocused) { focused in
                    guard focused else { return }
                    followLatest = true
                    hasNewBelow = false
                    scrollToLatest(proxy, animated: true)
                }
                .onAppear {
                    guard !PhotoViewerPresence.active else { return }
                    reload()
                    model.noteScroll("\(room) appear rows=\(messages.count) tail=\(messages.count - tailStart) viewport=\(Self.pt(viewportHeight)) "
                                     + "content=\(Self.pt(contentHeight)) anchor=\(BottomAnchoredTimeline.mode)")
                    followLatest = true
                    hasNewBelow = false
                    scrollToLatest(proxy, animated: false)
                }
                // #497: 이 방의 신호만 본다. 새 행이 있을 때만 움직인다 — 내 글은 최하단(부드럽게), 남의 글은 따라가는 중이면
                // 애니메이션 없이 한 번, 위로 읽는 중이면 「새 메시지」 버튼. 종전엔 어느 방의 신호든 따라가기를 켜고 애니메이션으로 내렸다.
                .onChange(of: model.roomRevision(room)) { _ in
                    let before = Set(messages.map(\.id))
                    reload()
                    let arrival = ScrollFollow.arrival(before: before, after: messages.map {
                        (id: $0.id, fromThisDevice: $0.outgoing != nil || $0.record.senderDevice == model.deviceId)
                    })
                    let action = ScrollFollow.afterReload(following: followLatest, arrival: arrival)
                    if arrival.mine || arrival.others {
                        model.noteScroll("\(room) new=\(arrival.mine ? "mine " : "")\(arrival.others ? "others" : "") rows=\(messages.count) tail=\(messages.count - tailStart) "
                                         + "following=\(followLatest) sentinel=\(Self.pt(tracking.sentinelBottom)) viewport=\(Self.pt(viewportHeight)) → \(action)")
                    }
                    switch action {
                    case .followAnimated:
                        followLatest = true
                        hasNewBelow = false
                        scrollToLatest(proxy, animated: true)
                        verifyPositionSoon(proxy)
                    case .follow:
                        // 앵커가 있으면 바닥 거리를 유지한 채 새 행이 아래에 붙어 그대로 보인다 — 명령을 내지 않는다(겹치면 꿈틀).
                        if !Self.anchored { scrollToLatest(proxy, animated: false) }
                        verifyPositionSoon(proxy)
                    case .markNewBelow:
                        hasNewBelow = true
                        verifyPositionSoon(proxy)
                    case .stay:
                        verifyPositionSoon(proxy)
                    }
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
        .navigationTitle(Strings.roomLabel(room))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // #405 P2: 제목 아래 불가에 둘러앉은 자리(사람 크림색 · 에이전트 파란색).
            ToolbarItem(placement: .principal) {
                VStack(spacing: 3) {
                    Text(Strings.roomLabel(room)).font(.headline).foregroundStyle(Hande.ink)
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

    /// 타임라인 한 행(날짜 구분선 + 말풍선). lazy 본문과 꼬리가 같은 행을 쓴다.
    @ViewBuilder private func row(_ item: AppModel.TimelineItem, _ proxy: ScrollViewProxy) -> some View {
        if let day = stamps[item.id]?.dayStart {
            DayDivider(text: Strings.dayLabel(day))
        }
        MessageRow(item: item, mine: item.record.isMine(device: model.deviceId),   // 같은 사람의 다른 기기도 내 글(오른쪽)
                   time: stamps[item.id]?.showTime == true ? item.record.receivedAt : nil,
                   roster: model.agentRoster, approval: approvalStates[item.id], canAnswer: isReady,
                   decide: { number, allow in answerApproval(number, allow: allow) },
                   onAttachmentLoaded: { attachmentLoaded(item.id, proxy) },
                   retry: { Task { await model.retry(outgoingId: item.id, room: room) } })
            .id(item.id)
    }

    /// #405 P2: 이 방의 자리 요약(제목 아래 점 · 작성창 안내).
    private var glance: RoomGlance { RoomGlance.make(messages.map(\.record), roster: model.agentRoster) }

    private var placeholder: String {
        guard let agent = glance.agents.last else { return Strings.composerPlaceholder }
        return Strings.composerPlaceholderAgent(AgentRoster.displayName(device: agent, names: Strings.agentNames))
    }

    private func reload() {
        messages = model.messages(room: room)
        // 꼬리 경계: 종전 첫 꼬리 행이 아직 있으면 그 자리(새 글·과거 글이 붙어도 행이 이사하지 않는다), 없으면 끝에서 `TimelineTail.rows`.
        tailStart = TimelineTail.start(ids: messages.map(\.id), anchor: tailAnchor)
        tailAnchor = tailStart < messages.count ? messages[tailStart].id : nil
        // #405 P3: 이 방을 보고 있다 = 마지막 글까지 읽음(이 기기에만). 보내는 글(음수 seq)은 읽음 표시에 넣지 않는다.
        if let last = messages.last(where: { $0.outgoing == nil }) { prefs.markRead(room, seq: last.id) }
        approvalStates = AgentApproval.states(messages.map(\.record), roster: model.agentRoster)
        stamps = TimelineStamps.compute(messages.map(\.record), calendar: .current)
    }

    /// #405 P1: 승인 카드 버튼 = 봇이 알아듣는 「승인 n」/「거절 n」 글을 대신 보낸다.
    private func answerApproval(_ number: Int, allow: Bool) {
        Task { _ = await model.send(room: room, text: Strings.approvalReply(number, allow: allow)) }
    }

    /// #472: 과거 글 한 페이지를 위에 붙인다. 보던 행(종전 첫 행)을 화면 위에 그대로 두어 점프하지 않는다 — 새 행이 붙은 뒤
    /// 한 런루프 뒤에 `scrollTo(anchor: .top)`(같은 틱에는 아직 배치되지 않아 조용히 무시된다, `scrollToLatest` 와 같은 이유).
    /// `messagesRevision` 은 올리지 않는다(그 경로는 "새 글 → 최하단").
    private func loadOlder(_ proxy: ScrollViewProxy) {
        guard let anchor = messages.first?.id, model.loadOlder(room: room) else { return }
        olderBusy = true
        let before = messages.count
        reload()
        guard messages.count > before else { olderBusy = false; return }   // 더 읽은 것이 없다(저장소 끝) — 창은 닿았다고 기록됐다.
        DispatchQueue.main.async {
            proxy.scrollTo(anchor, anchor: .top)
            olderBusy = false
        }
    }

    /// #398: 첨부 본체가 읽혀 행이 커졌다 — 끝 쪽 행이고 따라가는 중이면 최하단을 다시 맞춘다.
    private func attachmentLoaded(_ id: Int64, _ proxy: ScrollViewProxy) {
        guard !Self.anchored, ScrollFollow.shouldRescroll(loaded: id, ids: messages.map(\.id), following: followLatest) else { return }
        scrollToLatest(proxy, animated: false)
    }

    /// 마지막 메시지(seq 최대)로 스크롤한다. `messages` 를 바꾼 직후라 LazyVStack 이 아직 그 행을 배치하지 않았을 수 있으므로
    /// 한 런루프 뒤에 부른다 — 같은 틱에 부르면 앵커가 없어 조용히 무시된다(iOS 16 대상이라 `defaultScrollAnchor` 는 못 쓴다).
    /// #497: 같은 런루프의 요청(내용 증가·표지 실측·첨부 로딩·새 글)은 **하나**로 합친다 — 하나라도 즉시면 즉시. 애니메이션 스크롤 뒤에는
    /// 그동안 미룬 보정을 한 번 다시 잰다(애니메이션 중 즉시 보정이 끼어들어 위아래로 흔들렸다).
    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        // 목표는 높이 1pt 의 최하단 표지(「생각하는 중」 줄이 있으면 그 아래) — 높이 0 인 뷰는 scrollTo 가 끝까지 가지 않는다.
        guard !messages.isEmpty, tracking.request(animated: animated) else { return }
        let last = Self.bottomSentinelID
        let animation: TimeInterval = 0.2
        DispatchQueue.main.async {
            let animated = tracking.take()
            // 2차 계측: 실제로 낸 스크롤 명령(합친 뒤 1건) — 그 순간의 표지·내용 높이.
            model.noteScroll("\(room) scrollTo animated=\(animated) sentinel=\(Self.pt(tracking.sentinelBottom)) content=\(Self.pt(contentHeight)) viewport=\(Self.pt(viewportHeight))")
            if animated {
                tracking.animatingUntil = Date().addingTimeInterval(animation + 0.05)
                withAnimation(.easeOut(duration: animation)) { proxy.scrollTo(last, anchor: .bottom) }
                DispatchQueue.main.asyncAfter(deadline: .now() + animation + 0.1) {
                    if !Self.anchored, ScrollFollow.needsBottomCorrection(sentinelBottom: tracking.sentinelBottom, viewportHeight: viewportHeight,
                                                                          following: followLatest) {
                        correctBottom(proxy, reason: "after-animation")
                    }
                }
            } else {
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    /// 스크롤 위치가 내용 끝을 지나 빈 화면이 됐다(오너 보고 build 41) — 맨 아래로 되돌리고 따라간다. 맞췄으면 true.
    @discardableResult
    private func recoverIfPastContentEnd(_ proxy: ScrollViewProxy) -> Bool {
        guard !Self.anchored, ScrollFollow.isPastContentEnd(sentinelBottom: tracking.sentinelBottom, viewportHeight: viewportHeight,
                                            contentHeight: contentHeight, sinceDrag: Date().timeIntervalSince(tracking.lastDrag)) else { return false }
        model.noteScroll("\(room) past-end sentinel=\(Self.pt(tracking.sentinelBottom)) viewport=\(Self.pt(viewportHeight)) content=\(Self.pt(contentHeight)) → bottom")
        followLatest = true
        hasNewBelow = false
        scrollToLatest(proxy, animated: false)
        return true
    }

    // MARK: - 실측 보고(GeometryReader → 상태). 종전엔 PreferenceKey(`value = nextValue()` 축약)로 올렸는데 build 51 실기기에서
    // 칸 높이가 한 번도 도착하지 않았다(모든 scroll 줄 `viewport=0`). 처음 한 번 + 바뀔 때마다 직접 보고한다.

    private func viewportChanged(_ height: Double, _ proxy: ScrollViewProxy) {
        let old = viewportHeight
        viewportHeight = height
        if abs(height - old) >= 24 { model.noteScroll("\(room) viewport \(Self.pt(old))→\(Self.pt(height)) following=\(followLatest)") }
        // 앵커가 있으면 칸이 줄어도(키보드) 바닥 거리를 유지한다 — 명령 불필요.
        if !Self.anchored, ScrollFollow.shouldRescrollOnResize(old: old, new: height, following: followLatest) {
            scrollToLatest(proxy, animated: true)
        }
    }

    private func contentHeightChanged(_ height: Double, _ proxy: ScrollViewProxy) {
        let old = contentHeight
        contentHeight = height
        // 2차 계측: 내용 높이가 크게 바뀐 순간(lazy 행 실체화·추정치 변동·첨부 로딩) — 끌기와의 선후를 본다.
        if abs(height - old) >= 24 {
            model.noteScroll("\(room) content \(Self.pt(old))→\(Self.pt(height)) Δ\(Self.pt(height - old)) following=\(followLatest) "
                             + "sentinel=\(Self.pt(tracking.sentinelBottom)) sinceDrag=\(Self.ms(tracking.lastDrag))")
        }
        // 애니메이션 스크롤이 도는 동안은 보정을 내지 않는다 — 끝난 뒤 `scrollToLatest` 가 한 번 다시 잰다(#497: 둘이 싸워 흔들렸다).
        if !Self.anchored, !tracking.isAnimating, ScrollFollow.shouldRescrollOnContentGrowth(old: old, new: height, following: followLatest) {
            scrollToLatest(proxy, animated: false)
        }
    }

    private func bottomSentinelChanged(_ bottom: Double, _ proxy: ScrollViewProxy) {
        // 2차 계측: 바닥 표지가 한 번에 크게 움직였다(=화면이 튀었다) — 끌기·높이 변화·명령 중 무엇이 먼저였는지.
        let previous = tracking.sentinelBottom
        if previous.isFinite, abs(bottom - previous) >= 120 {
            model.noteScroll("\(room) sentinel-jump \(Self.pt(previous))→\(Self.pt(bottom)) Δ\(Self.pt(bottom - previous)) content=\(Self.pt(contentHeight)) "
                             + "viewport=\(Self.pt(viewportHeight)) following=\(followLatest) sinceDrag=\(Self.ms(tracking.lastDrag))")
        }
        tracking.sentinelBottom = bottom
        if recoverIfPastContentEnd(proxy) { return }
        if !Self.anchored, !tracking.isAnimating, ScrollFollow.needsBottomCorrection(sentinelBottom: bottom, viewportHeight: viewportHeight, following: followLatest) {
            correctBottom(proxy, reason: "sentinel")
        }
        refollowIfSettledAtBottom()
    }

    /// #472: 위로 끝까지 올라오면(따라가기가 꺼진 뒤에만) 과거 글 한 페이지를 위에 붙인다.
    private func topSentinelChanged(_ top: Double, _ proxy: ScrollViewProxy) {
        if ScrollFollow.shouldLoadOlder(sentinelBottom: top, following: followLatest, busy: olderBusy,
                                        exhausted: !model.canLoadOlder(room: room)) {
            loadOlder(proxy)
        }
    }

    /// 실측 보정(바닥 표지가 화면 아래에 남았다) — 진단 기록에 남기고 즉시 최하단.
    private func correctBottom(_ proxy: ScrollViewProxy, reason: String) {
        model.noteScroll("\(room) correct(\(reason)) sentinel=\(Self.pt(tracking.sentinelBottom)) viewport=\(Self.pt(viewportHeight)) → bottom")
        scrollToLatest(proxy, animated: false)
    }

    /// 바닥 앵커가 자리를 지키는 iOS 17+ — 즉시 보정 명령을 내지 않는다(`BottomAnchoredTimeline.isAnchored`).
    private static let anchored = BottomAnchoredTimeline.isAnchored

    /// 진단 기록용 pt 값(미측정 ∞ 는 그대로 표시 — `Int(.infinity)` 는 trap).
    private static func pt(_ value: Double) -> String { value.isFinite ? String(Int(value.rounded())) : "∞" }
    /// 진단 기록용 "그 시각부터 지금까지" ms(끌기 뒤 경과 등). `distantPast` 는 "없음".
    private static func ms(_ since: Date) -> String { since == .distantPast ? "-" : "\(Int(Date().timeIntervalSince(since) * 1000))ms" }

    /// 다시 읽은 뒤 몇 번 더 잰다 — 표지 실측이 다시 오지 않아도(배치가 멈춘 채 빈 화면·최하단 미달) 위치를 바로잡는다.
    private func verifyPositionSoon(_ proxy: ScrollViewProxy) {
        guard !Self.anchored else { return }   // 앵커가 자리를 지킨다 — 재측정 보정은 중복(꿈틀 원인).
        for delay in ScrollFollow.verifyDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if recoverIfPastContentEnd(proxy) { return }
                if !tracking.isAnimating, ScrollFollow.needsBottomCorrection(sentinelBottom: tracking.sentinelBottom, viewportHeight: viewportHeight,
                                                                             following: followLatest) {
                    correctBottom(proxy, reason: "verify@\(delay)")
                }
            }
        }
    }

    /// 끌기가 끝나 맨 아래에 멈췄으면 다시 따라간다(#497).
    private func refollowIfSettledAtBottom() {
        guard ScrollFollow.shouldRefollow(following: followLatest, sentinelBottom: tracking.sentinelBottom, viewportHeight: viewportHeight,
                                          sinceDrag: Date().timeIntervalSince(tracking.lastDrag)) else { return }
        followLatest = true
        hasNewBelow = false
    }

    /// 작성창 글을 보낸다. 암호화 전에 실패하면(동기화 실패·정지 등) 입력을 되돌린다 — 평문은 이 화면만 들고 있다.
    private func sendText(_ text: String) {
        guard isReady, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        previousDraft = ""
        draft = ""
        // 글은 누르는 즉시 목록에 오른다(`AppModel.outgoing`); 실패하면 말풍선 아래 「전송 안 됨 · 다시 보내기」 — 작성창에 되돌리지 않는다.
        Task { _ = await model.send(room: room, text: text) }
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
    /// 보내는 글이 실패했을 때 「다시 보내기」.
    var retry: () -> Void = {}
    private var message: MessageRecord { item.record }
    /// 받은(저장된) 첨부 말풍선 — 보내는 중인 첨부는 한 줄 글이라 종전 여백.
    private var isMedia: Bool { message.kind.isFile && item.outgoing == nil }
    /// 사진 말풍선의 테두리 두께(pt).
    static let mediaInset: CGFloat = 3

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

    /// 보내는 글의 상태(말풍선 아래): 보내는 중 · 연결되면 보냅니다 · 전송 안 됨 + 다시 보내기.
    @ViewBuilder private var outgoingStatus: some View {
        switch item.outgoing {
        case .sending?:
            Text(Strings.outgoingSending).font(.caption2).foregroundStyle(Hande.inkDim)
        case .queued?:
            Label(Strings.outgoingQueued, systemImage: "clock").font(.caption2).foregroundStyle(Hande.inkDim)
        case .failed(let reason)?:
            HStack(spacing: 6) {
                Label(Strings.outgoingFailed, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                Button(Strings.outgoingRetry, action: retry).buttonStyle(.borderless).foregroundStyle(Hande.ember)
            }
            .font(.caption2)
            .accessibilityHint(reason)
        case nil:
            EmptyView()
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
                    // 첨부(사진·파일)는 베젤을 최소화(오너 요청 2026-10-27) — 사진이 말풍선을 거의 채우고, 글 줄은 AttachmentBubble 이 자체 여백을 준다.
                    .padding(.horizontal, isMedia ? Self.mediaInset : 13)
                    .padding(.vertical, isMedia ? Self.mediaInset : 9)
                    .background(mine ? AnyShapeStyle(Hande.emberDeep) : AnyShapeStyle(Hande.surface))
                    .foregroundStyle(mine ? Hande.onEmber : Hande.ink)
                    .clipShape(BubbleShape(mine: mine))
                    .opacity(item.outgoing == nil ? 1 : 0.75)
                outgoingStatus
            }
            if !mine { timeLabel; Spacer(minLength: 40) }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .attachment where item.outgoing != nil, .fileV2 where item.outgoing != nil:
            // 아직 저장소에 없는 첨부(보내는 중): 본체 대신 종류·크기만.
            Text(Strings.outgoingAttachment).font(.footnote)
        case .attachment:
            AttachmentBubble(item: item, onLoaded: onAttachmentLoaded)
        case .fileV2:
            // 분리 첨부(#499): attachment 칸은 설명자(키) — 말풍선이 blob 을 받아 열고, 설명자는 화면·공유에 쓰지 않는다.
            AttachmentBubble(item: item, onLoaded: onAttachmentLoaded)
        case .undecryptable:
            Text(Strings.undecryptable)
        default:
            if Strings.serviceNames[message.senderActor] != nil {
                // 서비스 봇(알림 전용)만: 허용 링크(https://instagram.com/…)를 누를 수 있게 — 사람·에이전트 글은 그대로.
                Text(ServiceLinks.attributed(message.body))
            } else {
                Text(message.body)
            }
        }
    }
}

/// 첨부 말풍선: 본체는 보일 때 한 번 읽는다(#364 지연 로딩). 이미지는 미리보기(긴 변 ≤220pt), 그 밖은 종류·크기. 둘 다 저장·공유(ShareLink → 임시 파일).
/// #497: 준비물(축소 비트맵 + 공유 파일)은 `AttachmentPreviewCache` 에 행마다 한 번 — 꼬리↔LazyVStack 경계를 넘어 뷰가 새로 만들어져도
/// 첫 프레임부터 실제 높이다. body 는 디코드·파일 쓰기를 하지 않는다. 아직 준비 전인 사진은 고정 크기 자리로 높이 변화를 줄인다.
struct AttachmentBubble: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.displayScale) private var displayScale
    let item: AppModel.TimelineItem
    var onLoaded: () -> Void = {}
    @State private var preview: AttachmentPreview?
    /// 사진 탭 → 전체 화면 보기(오너 요청 build 30). 확대용 원본은 누를 때 디코드한다.
    @State private var viewerImage: UIImage?
    @State private var showViewer = false
    /// 본체를 끝내 읽지 못했다(재시도 소진) — 「불러오는 중」에 영원히 머물지 않게.
    @State private var unreadable = false
    /// file-v2 「다시 시도」 — 바뀌면 `.task(id:)` 가 다시 돈다.
    @State private var reload = 0
    /// file-v2 설명자의 평문 크기(받기 전 「불러오는 중」 표시용).
    @State private var v2Size: Int?

    /// 로딩 중 사진 자리(4:3 가로). 가로 사진은 높이가 그대로, 세로 사진은 +55pt 만 커진다(종전: 한 줄 → 220pt).
    static let placeholderSize = CGSize(width: AttachmentThumbnail.maxWidth, height: AttachmentThumbnail.maxWidth * 3 / 4)
    /// 저장소 읽기 재시도(앱·NSE 가 같은 DB 를 쓸 때 잠깐 잠길 수 있다).
    static let readAttempts = 3

    init(item: AppModel.TimelineItem, onLoaded: @escaping () -> Void = {}) {
        self.item = item
        self.onLoaded = onLoaded
        _preview = State(initialValue: AttachmentPreviewCache.shared.preview(room: item.record.room, seq: item.record.seq))
    }

    private var message: MessageRecord { item.record }
    /// 자리 표시 모양만 정한다(v1 = sniff 한 MIME, file-v2 = 보낸 쪽 힌트). 실제 미리보기 여부는 받은 내용으로 정한다.
    private var isImage: Bool { AttachmentFormat.isImage(mime: message.body) }
    private var isV2: Bool { message.kind == .fileV2 }
    /// 표시 크기: 준비물이 있으면 실제 바이트, v2 는 설명자 size, v1 은 저장된 본체 크기(v2 행의 attachmentBytes 는 설명자 길이라 쓰지 않는다).
    private var byteCount: Int { preview?.size ?? (isV2 ? (v2Size ?? 0) : item.attachmentBytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let thumbnail = preview?.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: AttachmentThumbnail.maxWidth, maxHeight: AttachmentThumbnail.maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: AttachmentThumbnail.cornerRadius))
                    .contentShape(RoundedRectangle(cornerRadius: AttachmentThumbnail.cornerRadius))
                    .onTapGesture { openViewer() }
                    .accessibilityLabel(Strings.attachmentImage)
                    .accessibilityAddTraits(.isButton)
            } else if preview == nil && !unreadable && isImage {
                // 4:3 자리 — 남은 폭이 280pt 보다 좁으면 그 폭에 맞춰 줄어든다(고정 폭이면 좁은 화면에서 넘친다).
                RoundedRectangle(cornerRadius: AttachmentThumbnail.cornerRadius)
                    .fill(Color.primary.opacity(0.06))
                    .aspectRatio(Self.placeholderSize.width / Self.placeholderSize.height, contentMode: .fit)
                    .frame(maxWidth: Self.placeholderSize.width)
                    .overlay(Text(Strings.attachmentLoading(byteCount)).font(.footnote))
            } else if preview == nil && !unreadable {
                Text(Strings.attachmentLoading(byteCount)).font(.footnote).modifier(AttachmentTextInset())
            } else if unreadable && isV2 {
                // 받기·검증·복호화 실패(403·404·410·변조·네트워크) — 타임라인은 그대로, 눌러서 다시 받는다(FILE-V2.md §4-3).
                Button { unreadable = false; reload += 1 } label: { Text(Strings.fileV2Failed(byteCount)).font(.footnote) }
                    .buttonStyle(.plain)
                    .modifier(AttachmentTextInset())
            } else {
                Text(Strings.attachmentFile(byteCount, preview?.mime ?? message.body)).font(.footnote).modifier(AttachmentTextInset())
            }
            if let url = preview?.shareURL {
                ShareLink(item: url) { Label(Strings.attachmentSave, systemImage: "square.and.arrow.up") }.font(.caption)
                    .modifier(AttachmentTextInset(bottomOnly: true))
            }
        }
        .fullScreenCover(isPresented: $showViewer, onDismiss: {
            // 밑의 방 화면이 다시 나타나는 콜백(onAppear)이 지난 뒤에 내린다.
            DispatchQueue.main.async { PhotoViewerPresence.active = false }
        }) {
            if let viewerImage {
                // 실제로 떴을 때만 세운다(못 뜨면 onDismiss 도 없어 영영 남는다).
                ImageViewer(image: viewerImage, shareURL: preview?.shareURL)
                    .onAppear { PhotoViewerPresence.active = true }
            }
        }
        .task(id: "\(message.seq)#\(reload)") {
            guard preview == nil else { return }
            if isV2 { await loadFileV2(); return }
            for attempt in 0..<Self.readAttempts {
                if let data = model.attachment(room: message.room, seq: message.seq) {
                    preview = await AttachmentPreviewCache.shared.prepare(record: message, bytes: data, scale: displayScale)
                    onLoaded()
                    return
                }
                if attempt + 1 < Self.readAttempts { try? await Task.sleep(nanoseconds: 700_000_000) }
                if Task.isCancelled { return }
            }
            unreadable = true
        }
    }

    /// file-v2(#499): 설명자 → blob 받기·검증·복호화 → **내용으로 MIME 을 정한** 표시용 행으로 준비물을 만든다.
    /// 표시용 행에는 설명자(키)를 싣지 않는다(attachment: nil, 바이트는 따로 넘긴다). 파일 바이트는 이력에 저장하지 않는다(§4-2).
    private func loadFileV2() async {
        guard let descriptor = model.fileV2Descriptor(room: message.room, seq: message.seq) else { unreadable = true; return }
        v2Size = descriptor.size
        do {
            let bytes = try await model.fileV2Bytes(room: message.room, seq: message.seq)
            if Task.isCancelled { return }
            let shown = MessageRecord(room: message.room, seq: message.seq, senderDevice: message.senderDevice, clientId: message.clientId,
                                      kind: .attachment, body: AttachmentFormat.sniffMime(bytes), attachment: nil,
                                      receivedAt: message.receivedAt, decryptedBy: message.decryptedBy)
            preview = await AttachmentPreviewCache.shared.prepare(record: shown, bytes: bytes, scale: displayScale)
            onLoaded()
        } catch {
            if !Task.isCancelled { unreadable = true }   // 화면 밖으로 나가 취소된 것은 실패가 아니다
        }
    }

    /// 전체 화면은 확대(최대 4배)가 있어 원본을 디코드한다 — 누를 때 한 번. file-v2 는 준비물의 공유 파일(복호화한 원본)에서 읽는다.
    private func openViewer() {
        let original = isV2 ? preview?.shareURL.flatMap { try? Data(contentsOf: $0) } : model.attachment(room: message.room, seq: message.seq)
        guard let data = original, let image = UIImage(data: data) else { return }
        viewerImage = image
        showViewer = true
    }
}

/// 첨부 말풍선 안의 글 줄 여백 — 말풍선 테두리는 3pt 뿐이라(사진용) 글은 여기서 숨 쉴 자리를 준다.
/// 「저장·공유」는 늘 앞 줄(사진·파일 줄) 뒤에 오고 위쪽 간격은 VStack 에 있으므로 좌우·아래만(`bottomOnly`).
struct AttachmentTextInset: ViewModifier {
    var bottomOnly = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.top, bottomOnly ? 0 : 6)
            .padding(.bottom, 6)
    }
}

/// #497: 전체 화면 사진 보기가 떠 있다. iOS 는 fullScreenCover 를 띄우고 닫을 때 밑의 방 화면에 onDisappear/onAppear 를 부를 수 있다 —
/// 그때 타임라인 창을 되돌리고(`resetTimelineWindow`) 최하단으로 가면 옛 사진을 보고 닫는 순간 보던 자리를 잃는다.
@MainActor
enum PhotoViewerPresence {
    static var active = false
}

/// 전체 화면 사진 보기: 검은 바탕 · UIKit 줌(핀치 위치 기준 1~4배, 두 번 탭은 탭 위치로 2.5배/원래, `ZoomableImageView`) · 저장·공유.
/// 닫기는 사진을 한 번 탭(X 버튼 없음). VoiceOver 는 「닫기」 접근성 동작.
struct ImageViewer: View {
    let image: UIImage
    let shareURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ZoomableImageView(image: image, onSingleTap: { dismiss() })
                .ignoresSafeArea()
            if let shareURL {
                ShareLink(item: shareURL) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel(Strings.attachmentSave)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(14)
            }
        }
        .accessibilityHint(Strings.attachmentViewerHint)
        .accessibilityAction(named: Text(Strings.attachmentViewerClose)) { dismiss() }
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

/// GeometryReader 가 잰 값을 바로 보고한다(처음 한 번 + 바뀔 때마다). PreferenceKey 축약(`value = nextValue()`)은 build 51 실기기에서
/// 칸 높이를 한 번도 올리지 못했다(모든 scroll 줄 `viewport=0`) — 상태 보고를 축약 순서에 기대지 않는다.
struct Measured: View {
    let value: Double
    let report: (Double) -> Void
    var body: some View {
        Color.clear
            .onAppear { report(value) }
            .onChange(of: value) { report($0) }
    }
}

/// #497 A4: 타임라인 스크롤의 기준점을 **바닥**으로. iOS 18+ 는 역할별로(처음 자리 = 바닥, 내용·칸 크기 변화 = 바닥 거리 유지),
/// iOS 17 은 한 값으로(세 역할 모두 바닥), iOS 16 은 API 가 없어 종전(위 기준 + 보정)대로. 어느 쪽이 적용됐는지는 `mode` 로 진단 기록에 남긴다.
/// 알려진 트레이드오프: 위로 읽는 중 새 글이 오면 그 글 높이만큼 보이는 행이 위로 밀린다(바닥 거리 유지) — 「새 메시지 ↓」 버튼은 그대로.
struct BottomAnchoredTimeline: ViewModifier {
    static var mode: String {
        if #available(iOS 18, *) { return "ios18-roles" }
        if #available(iOS 17, *) { return "ios17-single" }
        return "ios16-top"
    }

    /// 바닥 앵커가 살아 있다(iOS 17+). 이때 "최하단을 다시 맞추는" 즉시 보정(내용 증가·표지 실측·첨부 로딩·칸 축소·빈 화면 복구)은 앵커가
    /// 이미 하는 일이라 **중복**이고, 앵커의 조정과 같은 프레임에 겹쳐 꿈틀거림이 된다(오너 build 54: "점프는 없는데 계속 꿈틀") — 끈다.
    /// 남기는 명령은 사용자 의도가 있는 것뿐: 내 글 전송·「새 메시지 ↓」·작성창 포커스·방 진입.
    static var isAnchored: Bool {
        if #available(iOS 17, *) { return true }
        return false
    }

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else if #available(iOS 17, *) {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
    }
}

/// #472: 맨 위 표지의 아래 끝 y(스크롤 뷰 "timeline" 좌표) — 위로 밀려 있으면 음수, `ScrollFollow.olderPrefetch` 안으로 오면 과거 글을 읽는다.
