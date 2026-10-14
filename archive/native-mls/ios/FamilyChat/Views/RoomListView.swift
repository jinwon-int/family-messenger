// §9-3 대화 목록(고정 순서 displayOrder) + (+) 참여 요청·방 만들기 + 설정 진입.
import SwiftUI
import FamilyMLSCore

struct RoomListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showJoinRequest = false
    @State private var showCreateRoom = false

    var body: some View {
        List {
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
