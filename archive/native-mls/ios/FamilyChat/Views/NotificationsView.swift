// 🔔 알림 시트(#521, 웹 `openNotifySheet` 와 동일): 받은 로비 초대와 처리 상태(새 초대 / 수락하는 중… / 자동 수락 실패 n회 — 사유)를 모아
// 보이고 수락·다시 시도·무시를 받는다. 오너 기기의 자동 참여가 실패해도 로그가 아니라 여기와 목록 카드에 남는다. 행은 목록 카드와 같은
// `LobbyInviteRow` — 결과(참여·실패 상태·무시)는 `AppModel.pendingInvites`/`inviteStates` 로 돌아와 배지·카드에도 반영된다.
import SwiftUI
import FamilyMLSCore

struct NotificationsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.pendingInvites.isEmpty {
                    Text(Strings.notifyEmpty).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Section(Strings.inviteSectionTitle) {
                        ForEach(model.pendingInvites, id: \.room) { invite in
                            LobbyInviteRow(room: invite.room)
                        }
                    }
                }
                Section {
                    Text(Strings.notifyHint).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(Strings.notifyTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Strings.close) { dismiss() } }
            }
        }
    }
}
