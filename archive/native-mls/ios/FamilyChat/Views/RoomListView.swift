// §9-3 대화 목록(고정 순서 displayOrder) + 참여 요청(+) + 설정 진입.
import SwiftUI
import FamilyMLSCore

struct RoomListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showJoinRequest = false

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
                Button { showJoinRequest = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Strings.joinTitle)
                    .disabled(!model.canRequestJoin)
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showJoinRequest) { JoinRequestView().environmentObject(model) }
        .refreshable { await model.refresh() }
        .onAppear { model.refreshRooms() }
    }
}
