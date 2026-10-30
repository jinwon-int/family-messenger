// §9-3 대화 목록(고정 순서 displayOrder → #405 P3 이 기기 저장 순서 → #549 「↕ 순서」 모드 ▲▼·맨 위로 고정) + (+) 참여 요청·방 만들기 + 설정 진입.
import SwiftUI
import FamilyMLSCore

struct RoomListView: View {
    @EnvironmentObject private var model: AppModel
    /// #405 P3: 이 기기의 방 순서·읽음 표시.
    @EnvironmentObject private var prefs: LocalPrefs
    @State private var showJoinRequest = false
    @State private var showCreateRoom = false
    /// #521: 🔔 알림 시트(받은 초대와 처리 상태).
    @State private var showNotifications = false
    /// #405 P2: 방별 카드 요약(마지막 글·둘러앉은 자리). 목록 진입·새 메시지 때 다시 만든다.
    @State private var glances: [RoomID: RoomGlance] = [:]
    /// #549: 「↕ 순서」 모드(웹 한데 `orderEditing`) — 행마다 ▲▼, ≡ 끌기, 행 탭으로 방이 열리지 않음. 시스템 `편집` 대신 이 버튼이 켠다.
    @State private var editMode: EditMode = .inactive

    private var orderEditing: Bool { editMode.isEditing }

    var body: some View {
        List {
            // 오너 요청: 목록 머리 = 오프닝과 같은 hande 워드마크 + 「오늘 밤, 모닥불에 한데 모여」(내비게이션 큰 제목 대신).
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HandeWordmark(size: 32)
                    Text(Strings.campfireSubtitle).font(.footnote).foregroundStyle(Hande.inkDim)
                }
                .padding(.top, 4)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            if let notice = model.notice {
                Section {
                    HStack {
                        Text(notice).font(.footnote)
                        Spacer()
                        Button(Strings.close) { model.clearNotice() }.font(.footnote)
                    }
                }
            }
            // 오너 요청(2026-10-28): 받은 초대(수락·다시 시도·무시)는 목록에 칸을 두지 않고 🔔 알림 시트에만 둔다 —
            // 배지 수가 🔔 에 보이므로 목록은 대화방 카드만. 방이 하나도 없고 초대만 있으면 🔔 로 안내한다.
            if model.listedRooms.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Strings.campfireEmpty).font(.headline).foregroundStyle(Hande.ink)
                    Text(model.pendingInvites.isEmpty ? Strings.noRooms : Strings.invitesInBell(model.pendingInvites.count))
                        .font(.footnote).foregroundStyle(Hande.inkDim)
                }
                .listRowBackground(Color.clear)
            }
            // #549: 순서 모드 안내(웹 `orderHint`) — 고정 순서는 이 기기에만 저장된다는 것을 여기서 말한다.
            if orderEditing {
                Section {
                    Label(Strings.orderHint, systemImage: "arrow.up.arrow.down")
                        .font(.footnote).foregroundStyle(Hande.inkDim)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            ForEach(orderedRooms, id: \.room) { room in
                let glance = glances[room.room] ?? RoomGlance.make([], roster: model.agentRoster)
                // #571 B: 안 읽음 = 이 기기가 본 위치와 릴레이가 아는 같은 사람의 위치 중 큰 쪽 기준(웹 app.js mergeRelayRead 와 같다).
                let readSeq = max(prefs.readSeq[room.room] ?? 0, model.relayReadSeq[room.room] ?? 0)
                let card = CampfireCard(room: room, glance: glance,
                                        unread: Unread.isUnread(last: glance.last, myDevice: model.deviceId, readSeq: readSeq),
                                        muted: model.relayMuted[room.room] == true,
                                        // status-v1(#560, 오너 2026-10-30): 에이전트가 일하는 중이면 미리보기 대신 최신 「⏳ Working …」 줄.
                                        working: AgentStatusBoard.listLine(model.agentStatuses[room.room] ?? []))
                Group {
                    if orderEditing {
                        // 순서 모드: 방을 열지 않고 ▲▼(끝에서는 비활성) + 시스템 ≡ 끌기.
                        HStack(spacing: 8) {
                            card
                            OrderStepButtons(room: room.room, ids: orderedIds) { delta in stepRoom(room.room, by: delta) }
                        }
                    } else {
                        NavigationLink(value: room.room) { card }
                            // #549: 길게 눌러 「맨 위로 고정」(저장 순서 맨 앞) · 「순서」 모드 진입.
                            .contextMenu {
                                if orderedIds.first != room.room {
                                    Button { pinToTop(room.room) } label: { Label(Strings.orderPinTop, systemImage: "pin") }
                                }
                                if orderedIds.count > 1 {
                                    Button { setOrderEditing(true) } label: { Label(Strings.orderEditLabel, systemImage: "arrow.up.arrow.down") }
                                }
                            }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
            }
            // #405 P3: 순서 모드에서 끌어 순서를 바꾼다(웹 room-order.js — 최근 활동순으로 움직이지 않음, 이 기기에만 저장).
            .onMove { from, to in prefs.setOrder(RoomOrder.move(orderedIds, from: from, to: to)) }
        }
        .environment(\.editMode, $editMode)
        // 방이 하나뿐이 되면(나감·닫힘) 순서 모드는 뜻이 없다 — 조용히 끈다.
        .onChange(of: orderedRooms.count) { count in if count < 2 && orderEditing { setOrderEditing(false) } }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CampfireBackground())
        // 바 제목은 비우고(머리글이 제목 역할), 대화방의 뒤로 가기에는 hande 가 보이게 한다.
        .navigationTitle(Strings.wordmark)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadGlances)
        .onChange(of: model.messagesRevision) { _ in reloadGlances() }
        // `.id`: 방을 바꾸면(PageUp/Down · 목록) 새 화면 — 작성창 글(@State)이 다른 방으로 따라가 그 방 초안에 저장되지 않게.
        .navigationDestination(for: RoomID.self) { RoomView(room: $0).id($0) }
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
            // #549: 웹 한데의 「↕ 순서」/「완료」 — 시스템 `편집` 대신 무엇을 하는 버튼인지 보이게.
            if orderedRooms.count > 1 || orderEditing {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { setOrderEditing(!orderEditing) } label: {
                        if orderEditing {
                            Text(Strings.orderDone).fontWeight(.semibold)
                        } else {
                            Label(Strings.orderEdit, systemImage: "arrow.up.arrow.down").labelStyle(.titleAndIcon)
                        }
                    }
                    .accessibilityLabel(orderEditing ? Strings.orderDoneLabel : Strings.orderEditLabel)
                }
            }
            // #521: 🔔 받은 초대 수를 배지로(웹 `bellButton`). 오너 기기의 자동 참여 실패도 여기 남는다. #574: 승인 대기 새 기기·형제 초대 알림도 센다.
            ToolbarItem(placement: .primaryAction) {
                Button { showNotifications = true } label: {
                    Image(systemName: model.notificationCount == 0 ? "bell" : "bell.badge")
                        .overlay(alignment: .topTrailing) { InviteCountBadge(count: model.notificationCount) }
                }
                .accessibilityLabel(Strings.notifyButton(model.notificationCount))
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showJoinRequest = true } label: { Label(Strings.joinTitle, systemImage: "person.badge.key") }
                    Button { showCreateRoom = true } label: { Label(Strings.createTitle, systemImage: "flame") }
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Strings.roomActions)
                    .disabled(!model.canRequestJoin)
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showJoinRequest) { JoinRequestView().environmentObject(model) }
        .sheet(isPresented: $showCreateRoom) { CreateRoomView().environmentObject(model) }
        .sheet(isPresented: $showNotifications) { NotificationsView().environmentObject(model) }
        .refreshable { await model.refresh() }
        .onAppear { model.refreshRooms() }
    }
}

extension RoomListView {
    /// 저장된 순서를 먼저, 새 방은 기본 순서로 뒤에.
    fileprivate var orderedRooms: [RoomRecord] { RoomOrder.apply(model.listedRooms, saved: prefs.roomOrder) }
    fileprivate var orderedIds: [RoomID] { orderedRooms.map(\.room) }

    fileprivate func setOrderEditing(_ on: Bool) {
        withAnimation { editMode = on ? .active : .inactive }
    }

    /// ▲(−1)/▼(+1): 화면 순서에서 한 칸 옮겨 저장 — 저장 순서에 없던 방도 화면 순서로 함께 저장되므로 유실 없음.
    fileprivate func stepRoom(_ room: RoomID, by delta: Int) {
        guard let next = RoomOrder.step(orderedIds, room: room, by: delta) else { return }
        withAnimation { prefs.setOrder(next) }
    }

    /// 「맨 위로 고정」: 저장 순서 맨 앞으로.
    fileprivate func pinToTop(_ room: RoomID) {
        guard let next = RoomOrder.moveToTop(orderedIds, room: room) else { return }
        withAnimation { prefs.setOrder(next) }
    }

    fileprivate func reloadGlances() {
        var next: [RoomID: RoomGlance] = [:]
        for room in model.listedRooms {
            next[room.room] = RoomGlance.make(model.messages(room: room.room).map(\.record), roster: model.agentRoster)
        }
        glances = next
    }
}

/// #405 P2: 방 = 모닥불 카드. 에이전트가 있는 자리는 불이 밝고, 정지·닫힌 방은 장작만 남는다.
struct CampfireCard: View {
    let room: RoomRecord
    let glance: RoomGlance
    /// #405 P3: 이 기기에서 아직 안 본 남의 글이 있다(불씨 점 + 굵은 미리보기).
    var unread = false
    /// 방별 알림(server/mute.go): 이 사람이 이 방 알림을 껐다 — 이름 옆 🔕(웹 목록 `room-muted` 와 같다).
    var muted = false
    /// status-v1(#560): 이 방 에이전트의 지금 작업 줄(`⏳ Working — 10s | Bash: …`) — 있으면 미리보기 자리에 에이전트 색으로.
    /// 안 읽음 점·굵기·정렬은 바꾸지 않는다(저장된 글이 아니다). 답이 오거나 5분 지나면 nil → 평소 미리보기.
    var working: String? = nil

    private var out: Bool { room.haltedReason != nil }
    private var bright: Bool { glance.hasAgent && !out }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(out ? Color.white.opacity(0.06) : Hande.ember.opacity(bright ? 0.22 : 0.14))
                Text(out ? "🪵" : "🔥").font(.title3).saturation(out ? 0.3 : 1)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Strings.roomLabel(room.room)).font(.headline).foregroundStyle(out ? Hande.inkDim : Hande.ink)
                    if muted && !out {
                        Image(systemName: "bell.slash").font(.caption).foregroundStyle(Hande.inkDim)
                            .accessibilityLabel(Strings.mutedLabel)
                    }
                    if glance.hasAgent && !out {
                        Text(Strings.agentBadge).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Hande.agent.opacity(0.18)))
                            .foregroundStyle(Hande.agent)
                    }
                }
                if let working, !out {
                    Text(working).font(.footnote.weight(.medium))
                        .foregroundStyle(AgentPalette.accent).lineLimit(1).truncationMode(.tail)
                        .accessibilityLabel(Strings.agentWorkingListAccessibility(working))
                } else {
                    Text(preview).font(unread ? .footnote.weight(.semibold) : .footnote)
                        .foregroundStyle(unread ? Hande.ink : Hande.inkDim).lineLimit(1)
                }
                if !out && (!glance.people.isEmpty || glance.hasAgent) {
                    SeatDots(people: glance.people.count, agents: glance.agents.count, size: 7)
                }
            }
            Spacer(minLength: 0)
            // 오른쪽 칸: 위 = 마지막 말 시각(방금 · N분 전 · N시간 전 …, 오너 2026-10-30), 아래 = 안 읽음 점.
            VStack(alignment: .trailing, spacing: 8) {
                if let last = glance.last, !out {
                    // 목록을 열어 둔 동안에도 「N분 전」이 흘러가도록 30초마다 다시 그린다.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Strings.relativeTime(last.receivedAt, now: context.date))
                            .font(.caption2).foregroundStyle(unread ? Hande.ember : Hande.inkDim)
                            .fixedSize()
                    }
                }
                if unread && !out {
                    Circle().fill(Hande.ember).frame(width: 10, height: 10).shadow(color: Hande.ember.opacity(0.9), radius: 4)
                        .accessibilityLabel(Strings.unreadLabel)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(bright ? AnyShapeStyle(LinearGradient(colors: [Hande.ember.opacity(0.20), Hande.surface],
                                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                             : AnyShapeStyle(Hande.surface))
        )
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(bright ? Hande.ember.opacity(0.35) : Hande.stroke, lineWidth: 1))
        .shadow(color: bright ? Hande.ember.opacity(0.18) : .clear, radius: 12)
        .accessibilityElement(children: .combine)
    }

    private var preview: String {
        if out { return Strings.roomClosedPreview }
        guard let last = glance.last else { return Strings.roomNoMessages }
        let body = last.kind.isFile ? Strings.attachmentImage : last.body
        return Strings.previewLine(name: AgentRosterNames.person(last.senderDevice), body: body)
    }
}

/// #549: 순서 모드의 ▲▼(웹 한데 `orderUp`/`orderDown`). 끝에서는 비활성, 눌러도 방은 열리지 않는다(`.borderless` 로 행 탭과 분리).
struct OrderStepButtons: View {
    let room: RoomID
    let ids: [RoomID]
    let onStep: (Int) -> Void

    var body: some View {
        VStack(spacing: 6) {
            stepButton(delta: -1, symbol: "chevron.up", label: Strings.orderUp(room))
            stepButton(delta: 1, symbol: "chevron.down", label: Strings.orderDown(room))
        }
        .buttonStyle(.borderless)
    }

    private func stepButton(delta: Int, symbol: String, label: String) -> some View {
        let enabled = RoomOrder.canStep(ids, room: room, by: delta)
        return Button { onStep(delta) } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(Hande.surface))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Hande.stroke, lineWidth: 1))
                .foregroundStyle(enabled ? Hande.ink : Hande.inkDim.opacity(0.5))
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// 로비 초대 1탭(🔔 알림 시트 전용 — 목록 칸은 오너 요청 2026-10-28 로 뺌): 수락 = 방 상태를 로비 키로 받아들여 참여, 무시 = 이 세션에서 숨김(다음 실행에 다시 보임).
/// 가족 기기(오너 결정 D1 B)의 새 초대와, 오너 기기(A)의 자동 참여가 실패한 초대(#521 — 「다시 시도」가 횟수를 되돌린다)가 같은 줄을 쓴다.
struct LobbyInviteRow: View {
    @EnvironmentObject private var model: AppModel
    let room: RoomID
    @State private var busy = false
    @State private var message: String?

    private var state: AppModel.InviteState? { model.inviteStates[room] }
    /// 실패한 초대는 「수락」 대신 「다시 시도」.
    private var failed: Bool {
        if case .some(.failed) = state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.roomLabel(room)).font(.headline)
            Text(Strings.inviteBody(Strings.roomLabel(room))).font(.footnote).foregroundStyle(.secondary)
            InviteStateLine(state: state)
            if let message { Text(message).font(.footnote).foregroundStyle(.red) }
            HStack {
                Button(failed ? Strings.retryInvite : Strings.acceptInvite) { Task { await accept() } }.buttonStyle(.borderedProminent).disabled(busy)
                Button(Strings.ignoreInvite) { model.dismissInvite(room: room) }.buttonStyle(.bordered).disabled(busy)
                if busy { ProgressView() }
            }
        }
        .padding(.vertical, 4)
    }

    private func accept() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await model.acceptInvite(room: room)
        } catch {
            // 사유는 상태 줄(실패 n회 — 사유)에 있으면 그것을, 없으면 오류 원문을.
            if case .some(.failed(_, let reason?)) = model.inviteStates[room], !reason.isEmpty {
                message = Strings.inviteAcceptFailed(reason)
            } else {
                message = Strings.inviteAcceptFailed("\(error)")
            }
        }
    }
}

/// 초대 처리 상태 한 줄(웹 `inviteState`): 수락하는 중… / 자동 수락 실패 n회 — 사유. 새 초대는 비운다.
struct InviteStateLine: View {
    let state: AppModel.InviteState?

    var body: some View {
        switch state {
        case .some(.accepting):
            Text(Strings.inviteAccepting).font(.footnote).foregroundStyle(.secondary)
        case .some(.failed(let tries, let reason)):
            Text(Strings.inviteAutoFailed(tries, reason)).font(.footnote).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}

/// 🔔 배지: 받은 초대 수(목록 카드의 불씨 점과 같은 색). 0 이면 그리지 않는다.
struct InviteCountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.bold)).foregroundStyle(Hande.onEmber)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(Hande.ember))
                .offset(x: 8, y: -6)
                .accessibilityHidden(true)
        }
    }
}
