// §12-E 방 만들기: 이 기기에 로컬 그룹을 만든다(`AppModel.createRoom`). 릴레이의 방은 첫 초대 commit 이 만든다(relay-app §2).
import SwiftUI
import FamilyMLSCore

/// 대화방 ID 규칙(relay-app 과 같은 결): 영문 소문자·숫자로 시작, 소문자·숫자·하이픈 최대 48자.
enum RoomName {
    static func isValid(_ room: String) -> Bool {
        guard (1...48).contains(room.count), let first = room.unicodeScalars.first,
              ("a"..."z").contains(first) || ("0"..."9").contains(first) else { return false }
        return room.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}

struct CreateRoomView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var room = ""
    @State private var busy = false
    @State private var message: String?

    private var trimmed: String { room.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(Strings.createHint)) {
                    TextField(Strings.joinField, text: $room)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Button(Strings.createButton) { Task { await create() } }
                        .disabled(busy || trimmed.isEmpty || !model.canRequestJoin)
                }
            }
            .navigationTitle(Strings.createTitle)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(Strings.close) { dismiss() } } }
        }
    }

    private func create() async {
        guard RoomName.isValid(trimmed) else { message = Strings.roomIdInvalid; return }
        busy = true
        defer { busy = false }
        do {
            try await model.createRoom(room: trimmed)
            message = Strings.createDone
            dismiss()
        } catch {
            message = Strings.membershipFailure(error)
        }
    }
}
