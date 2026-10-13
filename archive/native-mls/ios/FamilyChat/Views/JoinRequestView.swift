// §12-E 최소 화면: 대화방 참여 요청 = 이 기기의 키 패키지를 방에 게시(`AppModel.requestJoin`). 초대는 운영자 기기(relay-app
// '초대')가 하므로 이 화면은 요청까지만 한다. 방 만들기·초대 화면은 아직 없음(NOTES-FINALIZER).
import SwiftUI
import FamilyMLSCore

struct JoinRequestView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var room: String = Strings.joinDefaultRoom
    @State private var busy = false
    @State private var message: String?

    private var trimmedRoom: String { room.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(Strings.joinHint)) {
                    TextField(Strings.joinField, text: $room)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(Strings.joinButton) { Task { await request() } }
                        .disabled(busy || trimmedRoom.isEmpty)
                }
            }
            .navigationTitle(Strings.joinTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Strings.close) { dismiss() } }
            }
        }
    }

    private func request() async {
        busy = true
        defer { busy = false }
        do {
            try await model.requestJoin(room: trimmedRoom)
            message = Strings.joinRequested
            dismiss()
        } catch {
            message = Strings.joinFailed("\(error)")
        }
    }
}
