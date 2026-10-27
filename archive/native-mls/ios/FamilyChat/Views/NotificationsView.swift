// 🔔 알림 시트(#521, 웹 `openNotifySheet` 와 동일): 받은 로비 초대와 처리 상태(새 초대 / 수락하는 중… / 자동 수락 실패 n회 — 사유)를 모아
// 보이고 수락·다시 시도·무시를 받는다. 오너 기기의 자동 참여가 실패해도 로그가 아니라 여기와 목록 카드에 남는다. 행은 목록 카드와 같은
// `LobbyInviteRow` — 결과(참여·실패 상태·무시)는 `AppModel.pendingInvites`/`inviteStates` 로 돌아와 배지·카드에도 반영된다.
import SwiftUI
import FamilyMLSCore

struct NotificationsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// 「진단 기록 복사」 뒤 잠깐 보이는 「복사했습니다」(#535).
    @State private var copied = false

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
                // #535: DevTools/Xcode 없이 실패 사유를 보고 — 기기·방·초대 상태 + 최근 기록을 클립보드로(비밀값 없음).
                Section {
                    Button {
                        UIPasteboard.general.string = model.diagnosticsReport()
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
                    } label: {
                        HStack {
                            Label(Strings.notifyCopyLogs, systemImage: "doc.on.doc")
                            Spacer()
                            if copied { Text(Strings.notifyCopied).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityIdentifier("notify-copy-logs")
                    Text(Strings.notifyCopyLogsHint).font(.footnote).foregroundStyle(.secondary)
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
