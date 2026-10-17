// §9-3 대화 목록(고정 순서 displayOrder) + (+) 참여 요청·방 만들기 + 설정 진입.
import SwiftUI
import FamilyMLSCore

struct RoomListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showJoinRequest = false
    @State private var showCreateRoom = false

    var body: some View {
        List {
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
            if model.rooms.isEmpty {
                Text(Strings.noRooms).foregroundStyle(.secondary)
            }
            ForEach(model.rooms, id: \.room) { room in
                NavigationLink(value: room.room) {
                    HStack {
                        Text(room.room)
                        if room.haltedReason != nil { Spacer(); Text("⛔") }
                    }
                }
            }
        }
        .navigationTitle(Strings.roomsTitle)
        .navigationDestination(for: RoomID.self) { RoomView(room: $0) }
        .toolbar {
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
