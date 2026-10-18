// §9-3 대화 목록(고정 순서 displayOrder) + (+) 참여 요청·방 만들기 + 설정 진입.
import SwiftUI
import FamilyMLSCore

struct RoomListView: View {
    @EnvironmentObject private var model: AppModel
    /// #405 P3: 이 기기의 방 순서·읽음 표시.
    @EnvironmentObject private var prefs: LocalPrefs
    @State private var showJoinRequest = false
    @State private var showCreateRoom = false
    /// #405 P2: 방별 카드 요약(마지막 글·둘러앉은 자리). 목록 진입·새 메시지 때 다시 만든다.
    @State private var glances: [RoomID: RoomGlance] = [:]

    var body: some View {
        List {
            // 오너 요청: 목록 머리 = 오프닝과 같은 HANDE 워드마크 + 「오늘 밤, 모닥불에 한데 모여」(내비게이션 큰 제목 대신).
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
            if !model.pendingInvites.isEmpty {
                Section(Strings.inviteSectionTitle) {
                    ForEach(model.pendingInvites, id: \.room) { invite in
                        LobbyInviteRow(room: invite.room)
                    }
                }
            }
            if model.listedRooms.isEmpty && model.pendingInvites.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Strings.campfireEmpty).font(.headline).foregroundStyle(Hande.ink)
                    Text(Strings.noRooms).font(.footnote).foregroundStyle(Hande.inkDim)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(orderedRooms, id: \.room) { room in
                let glance = glances[room.room] ?? RoomGlance.make([], roster: model.agentRoster)
                NavigationLink(value: room.room) {
                    CampfireCard(room: room, glance: glance,
                                 unread: Unread.isUnread(last: glance.last, myDevice: model.deviceId, readSeq: prefs.readSeq[room.room]))
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
            }
            // #405 P3: 「편집」에서 끌어 순서를 바꾼다(웹 room-order.js — 최근 활동순으로 움직이지 않음, 이 기기에만 저장).
            .onMove { from, to in prefs.setOrder(RoomOrder.move(orderedRooms.map(\.room), from: from, to: to)) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CampfireBackground())
        // 바 제목은 비우고(머리글이 제목 역할), 대화방의 뒤로 가기에는 HANDE 가 보이게 한다.
        .navigationTitle(Strings.wordmark)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadGlances)
        .onChange(of: model.messagesRevision) { _ in reloadGlances() }
        .navigationDestination(for: RoomID.self) { RoomView(room: $0) }
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
            if orderedRooms.count > 1 {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
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
        .refreshable { await model.refresh() }
        .onAppear { model.refreshRooms() }
    }
}

extension RoomListView {
    /// 저장된 순서를 먼저, 새 방은 기본 순서로 뒤에.
    fileprivate var orderedRooms: [RoomRecord] { RoomOrder.apply(model.listedRooms, saved: prefs.roomOrder) }

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
                    Text(room.room).font(.headline).foregroundStyle(out ? Hande.inkDim : Hande.ink)
                    if glance.hasAgent && !out {
                        Text(Strings.agentBadge).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Hande.agent.opacity(0.18)))
                            .foregroundStyle(Hande.agent)
                    }
                }
                Text(preview).font(unread ? .footnote.weight(.semibold) : .footnote)
                    .foregroundStyle(unread ? Hande.ink : Hande.inkDim).lineLimit(1)
                if !out && (!glance.people.isEmpty || glance.hasAgent) {
                    SeatDots(people: glance.people.count, agents: glance.agents.count, size: 7)
                }
            }
            Spacer(minLength: 0)
            if unread && !out {
                Circle().fill(Hande.ember).frame(width: 10, height: 10).shadow(color: Hande.ember.opacity(0.9), radius: 4)
                    .accessibilityLabel(Strings.unreadLabel)
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
        let body = last.kind == .attachment ? Strings.attachmentImage : last.body
        return Strings.previewLine(name: AgentRosterNames.person(last.senderDevice), body: body)
    }
}

/// 가족 기기(오너 결정 D1 B)의 로비 초대 1탭: 수락 = 방 상태를 로비 키로 받아들여 참여, 무시 = 이 세션에서 숨김(다음 실행에 다시 보임).
struct LobbyInviteRow: View {
    @EnvironmentObject private var model: AppModel
    let room: RoomID
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(room).font(.headline)
            Text(Strings.inviteBody(room)).font(.footnote).foregroundStyle(.secondary)
            if let message { Text(message).font(.footnote).foregroundStyle(.red) }
            HStack {
                Button(Strings.acceptInvite) { Task { await accept() } }.buttonStyle(.borderedProminent).disabled(busy)
                Button(Strings.ignoreInvite) { model.dismissInvite(room: room) }.buttonStyle(.bordered).disabled(busy)
                if busy { ProgressView() }
            }
        }
        .padding(.vertical, 4)
    }

    private func accept() async {
        busy = true
        defer { busy = false }
        do { try await model.acceptInvite(room: room) } catch { message = Strings.inviteAcceptFailed("\(error)") }
    }
}
