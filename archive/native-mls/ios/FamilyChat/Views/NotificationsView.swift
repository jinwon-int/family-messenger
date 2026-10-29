// 🔔 알림 시트(#521, 웹 `openNotifySheet` 와 동일): 받은 로비 초대와 처리 상태(새 초대 / 수락하는 중… / 자동 수락 실패 n회 — 사유)를 모아
// 보이고 수락·다시 시도·무시를 받는다. 오너 기기의 자동 참여가 실패해도 로그가 아니라 여기 남는다. 초대 칸은 이 시트에만 있다(오너 요청
// 2026-10-28 — 대화 목록에는 두지 않고 🔔 배지 수로만 알린다). 행은 `LobbyInviteRow` — 결과(참여·실패 상태·무시)는
// `AppModel.pendingInvites`/`inviteStates` 로 돌아와 배지에도 반영된다.
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
                if model.notificationCount == 0 {
                    Text(Strings.notifyEmpty).font(.footnote).foregroundStyle(.secondary)
                }
                // #574: 같은 계정의 새 기기가 우편함에 올린 승인 요청 — 지문 비교 시트로 승인하거나 무시(웹 `candidateCard`).
                if !model.candidates.isEmpty {
                    Section(Strings.candidatesSectionTitle) {
                        ForEach(model.candidates, id: \.deviceId) { candidate in
                            CandidateRow(candidate: candidate)
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
                // #574: 승인한 형제 기기 초대의 포기·실패(웹 `noteRows`).
                if !model.siblingNotes.isEmpty {
                    Section(Strings.siblingNotesTitle) {
                        ForEach(model.siblingNotes) { note in
                            HStack(alignment: .top) {
                                Text(note.text).font(.footnote)
                                Spacer()
                                Button(Strings.dismissNote) { model.dismissSiblingNote(note.id) }.font(.footnote).buttonStyle(.bordered)
                            }
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
