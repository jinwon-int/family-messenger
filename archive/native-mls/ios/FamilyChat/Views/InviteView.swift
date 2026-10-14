// §12-E 초대: 상대 기기의 키 패키지를 소비해 Add commit + Welcome 을 올린다(`AppModel.invite`, relay-app `초대`와 같은 순서).
// 상대가 먼저 이 방에 '참여 요청'(키 패키지 게시)을 해 두어야 한다 — 없으면 원인과 다음 행동을 안내한다.
import SwiftUI
import FamilyMLSCore

/// 기기 ID 규칙(릴레이 `validIdentifier`): 영문·숫자·`-`·`_`, 1~64자.
enum DeviceName {
    static func isValid(_ id: String) -> Bool {
        guard (1...64).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }
}

struct InviteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let room: RoomID
    @State private var target = ""
    @State private var busy = false
    @State private var message: String?

    private var trimmed: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(room), footer: Text(Strings.inviteHint)) {
                    TextField(Strings.inviteField, text: $target)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Button(Strings.inviteButton) { Task { await invite() } }
                        .disabled(busy || trimmed.isEmpty || !model.canRequestJoin)
                    if busy { ProgressView() }
                }
            }
            .navigationTitle(Strings.inviteTitle)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(Strings.close) { dismiss() } } }
        }
    }

    private func invite() async {
        guard DeviceName.isValid(trimmed) else { message = Strings.deviceIdInvalid; return }
        guard trimmed != model.deviceId else { message = Strings.inviteSelf; return }
        busy = true
        defer { busy = false }
        do {
            try await model.invite(room: room, target: trimmed)
            message = Strings.inviteDone(trimmed)
            await model.refresh()
        } catch {
            message = Strings.membershipFailure(error)
        }
    }
}
