// §9-3 대화 목록(고정 순서 displayOrder) + 설정 진입.
import SwiftUI
import FamilyMLSCore

struct RoomListView: View {
    @EnvironmentObject private var model: AppModel

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
            NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
        }
        .refreshable { model.refreshRooms() }
        .onAppear { model.refreshRooms() }
    }
}
