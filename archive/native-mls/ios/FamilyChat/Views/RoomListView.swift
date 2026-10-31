// §9-3 대화 목록(고정 순서 displayOrder → #405 P3 이 기기 저장 순서 → #549 「↕ 순서」 모드 ▲▼·맨 위로 고정) + (+) 참여 요청·방 만들기 + 설정 진입.
import SwiftUI
import FamilyMLSCore

struct RoomListView: View {
    @EnvironmentObject private var model: AppModel
    /// #405 P3: 이 기기의 방 순서·읽음 표시.
    @EnvironmentObject private var prefs: LocalPrefs
    /// 오너 2026-10-31: 행 오른쪽 「>」 없이 카드를 끝까지 — NavigationLink 대신 이 경로로 연다(FamilyChatApp 이 주입).
    @EnvironmentObject private var navigator: Navigator
    @State private var showJoinRequest = false
    @State private var showCreateRoom = false
    /// #521: 🔔 알림 시트(받은 초대와 처리 상태).
    @State private var showNotifications = false
    /// #405 P2: 방별 카드 요약(마지막 글·둘러앉은 자리). 목록 진입·새 메시지 때 다시 만든다.
    @State private var glances: [RoomID: RoomGlance] = [:]
    /// #549: 「↕ 순서」 모드(웹 한데 `orderEditing`) — 행마다 ▲▼, ≡ 끌기, 행 탭으로 방이 열리지 않음. 시스템 `편집` 대신 이 버튼이 켠다.
    @State private var editMode: EditMode = .inactive
    @Environment(\.hande) private var p

    private var orderEditing: Bool { editMode.isEditing }

    var body: some View {
        List {
            // 오너 요청: 목록 머리 = 오프닝과 같은 hande 워드마크 + 「오늘 밤, 모닥불에 한데 모여」(내비게이션 큰 제목 대신).
            // 디자인 2차 2c: 순서 모드에서는 머리를 「자리 순서」 + 주황 「완료」 + 안내 한 줄로 바꿔 모드가 바뀐 것이 분명하게.
            Section {
                if orderEditing {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center) {
                            Text(Strings.orderModeTitle).font(.system(size: 22, weight: .semibold)).foregroundStyle(p.ink)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Button { setOrderEditing(false) } label: {
                                Text(Strings.orderDone)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(p.onEmber)
                                    .padding(.horizontal, 16)
                                    .frame(height: 36)
                                    .background(Capsule().fill(p.ember))
                                    .overlay(Capsule().stroke(p.isDay ? p.stroke : .clear, lineWidth: p.lineWidth))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Strings.orderDoneLabel)
                            .accessibilityIdentifier("rooms-order-done")
                        }
                        Text(Strings.orderHint).font(.system(size: 14)).foregroundStyle(p.inkDim)
                    }
                    .padding(.top, 4)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .moveDisabled(true)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HandeWordmark(size: 34)
                        Text(Strings.campfireSubtitle).font(.subheadline).foregroundStyle(p.inkDim)
                    }
                    .padding(.top, 4)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
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
            // 디자인 2차 2c: 빈 상태에만 불 그림(꺼진 장작 + 불씨 1점 + 흐린 자리 점 2) — 초대가 있으면 건수 없이 「있어요」 카드.
            if model.listedRooms.isEmpty {
                Section {
                    VStack(spacing: 16) {
                        EmptyCampfireArt()
                        Text(Strings.campfireEmpty).font(.system(size: 20, weight: .semibold)).foregroundStyle(p.ink)
                            .multilineTextAlignment(.center)
                        Text(Strings.emptyRoomsHint).font(.system(size: 15)).foregroundStyle(p.inkDim)
                            .multilineTextAlignment(.center)
                        if !model.pendingInvites.isEmpty {
                            HStack(spacing: 10) {
                                Circle().fill(p.ember).frame(width: 8, height: 8).accessibilityHidden(true)
                                Text(Strings.invitesInBellPlain).font(.system(size: 15)).foregroundStyle(p.ink)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .handeCard()
                            .padding(.top, 8)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("rooms-empty-invites")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 56)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("rooms-empty")
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
                        // 순서 모드(디자인 2차 2c): 불 세기·미리보기·안 읽음은 숨기고 이름 + 고정 핀 + ▲▼ 만(끝에서는 비활성) + 시스템 ≡ 끌기.
                        // 방은 열리지 않는다. 꺼진 자리는 60% 흐림 + 고정 불가.
                        OrderRow(room: room, isFirst: orderedIds.first == room.room,
                                 steps: OrderStepButtons(room: room.room, ids: orderedIds) { delta in stepRoom(room.room, by: delta) },
                                 onPin: { pinToTop(room.room) })
                    } else {
                        // 오너 2026-10-31: List 안 NavigationLink 는 행 오른쪽에 「>」를 붙여 카드가 그만큼 좁아진다 —
                        // 평범한 버튼으로 같은 경로(navigator.open = path [room])를 열어 표시를 없애고 카드를 오른쪽 끝까지 쓴다.
                        Button { navigator.open(room.room) } label: { card }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("room-row")
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
        // 오너 2026-10-31: 목록 아래 「불 피우기」 알약은 뺀다 — 목록이 화면 아래까지 늘어난다.
        // 방 만들기는 오른쪽 위 + 메뉴에 그대로 있다(웹 한데 ⚙ 메뉴 · Android 와 같은 결).
        // 바 제목은 비우고(머리글이 제목 역할), 대화방의 뒤로 가기에는 hande 가 보이게 한다.
        .navigationTitle(Strings.wordmark)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadGlances)
        .onChange(of: model.messagesRevision) { _ in reloadGlances() }
        // `.id`: 방을 바꾸면(PageUp/Down · 목록) 새 화면 — 작성창 글(@State)이 다른 방으로 따라가 그 방 초안에 저장되지 않게.
        .navigationDestination(for: RoomID.self) { RoomView(room: $0).id($0) }
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
            // #549: 웹 한데의 「↕ 순서」 — 시스템 `편집` 대신 무엇을 하는 버튼인지 보이게. 자리가 0~1개면 숨김(디자인 2차 2c).
            // 「완료」는 순서 모드의 머리(「자리 순서」 옆 주황 알약)에만 — 바에 또 두지 않는다.
            if orderedRooms.count > 1 && !orderEditing {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { setOrderEditing(true) } label: {
                        Label(Strings.orderEdit, systemImage: "arrow.up.arrow.down").labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel(Strings.orderEditLabel)
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

/// #405 P2 → 디자인 1차 1b: 방 = 모닥불 카드(면 + 따뜻한 선, 반경 16). 아이콘 원 안 불꽃 1~3단 = 오늘의 불 세기(숫자 없음),
/// 불지기 배지(파랑), 자리 점, 안 읽음 = 주황 점 하나(개수 없음). 꺼진 자리는 60% 흐림 + 장작 아이콘.
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
    @Environment(\.hande) private var p

    private var out: Bool { room.haltedReason != nil }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(out ? p.ink.opacity(0.05) : p.ember.opacity(0.12))
                if out {
                    LogIcon(size: 24)
                } else {
                    FlameIcon(level: glance.fireLevel, size: 26)
                }
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(Strings.roomLabel(room.room)).font(.headline).foregroundStyle(out ? p.inkDim : p.ink)
                        .lineLimit(1).truncationMode(.tail)
                    if muted && !out {
                        Image(systemName: "bell.slash").font(.caption).foregroundStyle(p.inkDim)
                            .accessibilityLabel(Strings.mutedLabel)
                    }
                    // 「불지기」 배지는 넣지 않는다(오너 2026-10-31 #613 — 웹 #540 과 같다; 디자인 1차 1b 의 배지보다 이 결정이 우선).
                    // 에이전트 자리는 SeatDots 의 파란 점으로 보인다.
                }
                if let working, !out {
                    Text(working).font(.footnote.weight(.medium))
                        .foregroundStyle(p.agentText).lineLimit(1).truncationMode(.tail)
                        .accessibilityLabel(Strings.agentWorkingListAccessibility(working))
                } else {
                    Text(preview).font(unread ? .footnote.weight(.semibold) : .footnote)
                        .foregroundStyle(unread ? p.ink : p.inkDim).lineLimit(1)
                }
                if !out && (!glance.people.isEmpty || glance.hasAgent) {
                    SeatDots(people: glance.people.count, agents: glance.agents.count, size: 8)
                }
            }
            Spacer(minLength: 0)
            // 오른쪽 칸: 위 = 마지막 말 시각(방금 · N분 전 · N시간 전 …, 오너 2026-10-30), 아래 = 안 읽음 점.
            VStack(alignment: .trailing, spacing: 8) {
                if let last = glance.last, !out {
                    // 목록을 열어 둔 동안에도 「N분 전」이 흘러가도록 30초마다 다시 그린다.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Strings.relativeTime(last.receivedAt, now: context.date))
                            .font(.caption2).foregroundStyle(p.inkDim)
                            .fixedSize()
                    }
                }
                if unread && !out {
                    Circle().fill(p.ember).frame(width: 10, height: 10).shadow(color: p.ember.opacity(0.6 * p.glow), radius: 4)
                        .accessibilityLabel(Strings.unreadLabel)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Hande.radiusM).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: Hande.radiusM).stroke(p.stroke, lineWidth: p.lineWidth))
        .opacity(out ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    private var preview: String {
        if out { return room.haltedReason == SyncHaltReason.roomClosed ? Strings.roomClosedByOperator : Strings.roomClosedPreview }
        guard let last = glance.last else { return Strings.roomNoMessages }
        let body = last.kind.isFile ? Strings.attachmentImage : last.body
        // 1:1 방은 방 이름이 곧 상대라 「이름: 」 접두를 빼고 내용만(오너 2026-10-30, 웹 한데와 같다). 여럿이 말한 방은 누가 했는지 남긴다.
        return Strings.previewLine(name: glance.isOneToOne ? "" : AgentRosterNames.person(last.senderDevice), body: body)
    }
}

/// #549: 순서 모드의 ▲▼(웹 한데 `orderUp`/`orderDown`). 끝에서는 비활성, 눌러도 방은 열리지 않는다(`.borderless` 로 행 탭과 분리).
/// 디자인 2차 2c: 각 40×22, 주황 글자, 면 없음 — 끌기가 어려운 조부모용.
struct OrderStepButtons: View {
    let room: RoomID
    let ids: [RoomID]
    let onStep: (Int) -> Void
    @Environment(\.hande) private var p

    var body: some View {
        VStack(spacing: 0) {
            stepButton(delta: -1, symbol: "chevron.up", label: Strings.orderUp(room))
            stepButton(delta: 1, symbol: "chevron.down", label: Strings.orderDown(room))
        }
        .buttonStyle(.borderless)
    }

    private func stepButton(delta: Int, symbol: String, label: String) -> some View {
        let enabled = RoomOrder.canStep(ids, room: room, by: delta)
        return Button { onStep(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 40, height: 22)
                .contentShape(Rectangle())
                .foregroundStyle(enabled ? p.ember : p.inkDim.opacity(0.35))
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// 디자인 2차 2c: 순서 모드의 행 — 카드(면 + 선) 안에 이름 17/600 + 보조 13(「맨 위 고정」 / 「불이 꺼진 자리 · 운영자가 닫음」) +
/// 고정 핀 40pt(켜짐 = 주황 16% 면 + 주황 핀, 꺼짐 = 면 없이 보조색) + ▲▼. 불 세기·미리보기·안 읽음은 보이지 않는다.
/// 끌기 손잡이 ≡ 는 List 편집 모드의 시스템 손잡이(오른쪽)를 그대로 쓴다 — 같은 손잡이를 둘 그리지 않는다.
struct OrderRow: View {
    let room: RoomRecord
    let isFirst: Bool
    let steps: OrderStepButtons
    let onPin: () -> Void
    @Environment(\.hande) private var p

    private var out: Bool { room.haltedReason != nil }
    private var note: String? {
        if out { return Strings.roomClosedByOperator }
        return isFirst ? Strings.orderPinnedNote : nil
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.roomLabel(room.room)).font(.system(size: 17, weight: .semibold)).foregroundStyle(p.ink)
                    .lineLimit(1).truncationMode(.tail)
                if let note {
                    Text(note).font(.system(size: 13)).foregroundStyle(p.inkDim).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: onPin) {
                Image(systemName: isFirst ? "pin.fill" : "pin")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isFirst ? p.ember : p.inkDim)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(isFirst ? p.ember.opacity(0.16) : Color.clear))
            }
            .buttonStyle(.borderless)
            .disabled(isFirst || out)
            .accessibilityLabel(Strings.orderPinTop)
            steps
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .handeCard()
        .opacity(out ? 0.6 : 1)
    }
}

/// 디자인 2차 2c: 목록 빈 상태 그림(96×64) — 꺼진 장작 두 토막 + 가지 둘(재 색) + 남은 불씨 1점 + 둘러앉을 자리 점 2개(크림·파랑, 흐림).
/// 불 그림은 이 빈 상태에만 쓴다. 정적(움직이지 않는다).
struct EmptyCampfireArt: View {
    @Environment(\.hande) private var p
    /// 디자인 원문 SVG path(장작 2 + 가지 2) — SVGPathData 는 M/L/H/V/C/Q/Z 만 읽는다.
    static let logs = "M18 50h60M22 58h52M30 46l14-12M66 46L52 34"
    static let size = CGSize(width: 96, height: 64)

    var body: some View {
        ZStack {
            OpeningArt.path(Self.logs)
                .stroke(p.ash, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            Circle().fill(p.ember.opacity(0.7)).frame(width: 6, height: 6).position(x: 48, y: 30)
            Circle().fill(p.person.opacity(0.5)).frame(width: 8, height: 8).position(x: 20, y: 40)
            Circle().fill(p.agent.opacity(0.5)).frame(width: 8, height: 8).position(x: 76, y: 40)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }
}

/// 로비 초대 1탭(🔔 알림 시트 전용 — 목록 칸은 오너 요청 2026-10-28 로 뺌): 수락 = 방 상태를 로비 키로 받아들여 참여, 무시 = 이 세션에서 숨김(다음 실행에 다시 보임).
/// 가족 기기(오너 결정 D1 B)의 새 초대와, 오너 기기(A)의 자동 참여가 실패한 초대(#521 — 「다시 시도」가 횟수를 되돌린다)가 같은 줄을 쓴다.
/// 디자인 2차 2e — 카드 3상태: 기본(수락 주 44pt / 무시 보조) · 수락하는 중(크림 점 3 + 글자, 버튼 자리 대체) ·
/// 실패(카드 선 붉은 잉걸 45% + 사람 말 한 줄, 「다시 시도」/「무시」). 실패 횟수 숫자·기술 사유는 진단 기록으로.
struct LobbyInviteRow: View {
    @EnvironmentObject private var model: AppModel
    let room: RoomID
    /// 초대가 올라온 시각(릴레이 `created_at`, Unix 초) — 카드 머리의 「방금 · N분 전」. 모르면 nil.
    var createdAt: Int64? = nil
    @State private var busy = false
    @State private var message: String?
    @Environment(\.hande) private var p

    private var state: AppModel.InviteState? { model.inviteStates[room] }
    /// 실패한 초대는 「수락」 대신 「다시 시도」.
    private var failed: Bool {
        if case .some(.failed) = state { return true }
        return false
    }
    private var accepting: Bool {
        if case .some(.accepting) = state { return true }
        return busy
    }
    private var tries: Int {
        if case .some(.failed(let tries, _)) = state { return tries }
        return 0
    }
    private var label: String { Strings.roomLabel(room) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.inviteKickerLine(relativeTime)).font(.system(size: 13)).foregroundStyle(p.inkDim)
            Text(failed ? Strings.inviteFailedTitle(label) : Strings.inviteCardBody(label))
                .font(.system(size: 16)).foregroundStyle(p.ink)
                .fixedSize(horizontal: false, vertical: true)
            if failed {
                Text(Strings.inviteAutoFailedPlain(tries)).font(.system(size: 14)).foregroundStyle(p.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message { Text(message).font(.system(size: 13)).foregroundStyle(p.warn) }
            if accepting {
                HStack(spacing: 10) {
                    DotsRow(color: p.person, size: 8)
                    Text(Strings.inviteAccepting).font(.system(size: 15)).foregroundStyle(p.inkDim)
                }
                .frame(height: 28)
            } else {
                HStack(spacing: 8) {
                    if failed {
                        Button(Strings.retryInvite) { Task { await accept() } }
                            .buttonStyle(HandeSecondaryButtonStyle())
                            .accessibilityIdentifier("invite-accept")
                    } else {
                        Button(Strings.acceptInvite) { Task { await accept() } }
                            .buttonStyle(HandePrimaryButtonStyle())
                            .accessibilityIdentifier("invite-accept")
                    }
                    Button(Strings.ignoreInvite) { model.dismissInvite(room: room) }
                        .buttonStyle(HandeSecondaryButtonStyle())
                        .accessibilityIdentifier("invite-ignore")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .handeCard(stroke: failed ? p.warn.opacity(0.45) : nil)
    }

    private var relativeTime: String? {
        guard let createdAt, createdAt > 0 else { return nil }
        return Strings.relativeTime(Date(timeIntervalSince1970: TimeInterval(createdAt)))
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
    @Environment(\.hande) private var p

    var body: some View {
        switch state {
        case .some(.accepting):
            Text(Strings.inviteAccepting).font(.footnote).foregroundStyle(p.inkDim)
        case .some(.failed(let tries, let reason)):
            Text(Strings.inviteAutoFailed(tries, reason)).font(.footnote).foregroundStyle(p.warn)
        default:
            EmptyView()
        }
    }
}

/// 🔔 배지: 받은 초대 수(목록 카드의 불씨 점과 같은 색). 0 이면 그리지 않는다.
struct InviteCountBadge: View {
    let count: Int
    @Environment(\.hande) private var p

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.bold)).foregroundStyle(p.onEmber)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(p.ember))
                .offset(x: 8, y: -6)
                .accessibilityHidden(true)
        }
    }
}
