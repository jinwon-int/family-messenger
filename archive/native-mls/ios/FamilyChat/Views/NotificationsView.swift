// 🔔 알림 시트(#521, 웹 `openNotifySheet` 와 동일): 받은 로비 초대와 처리 상태(새 초대 / 수락하는 중… / 자동 수락 실패)를 모아
// 보이고 수락·다시 시도·무시를 받는다. 오너 기기의 자동 참여가 실패해도 로그가 아니라 여기 남는다. 초대 칸은 이 시트에만 있다(오너 요청
// 2026-10-28 — 대화 목록에는 두지 않고 🔔 배지 수로만 알린다). 행은 `LobbyInviteRow` — 결과(참여·실패 상태·무시)는
// `AppModel.pendingInvites`/`inviteStates` 로 돌아와 배지에도 반영된다.
// 디자인 2차 2e(2026-10-31): 모닥불 배경 위 카드. 오른쪽 위 글자 버튼 「기록 복사」(#535 진단 기록 → 토스트 「복사했어요」).
// 빈 상태는 그림 없이 흐린 자리 점 3개만(불 그림은 목록 빈 상태 하나로 제한).
import SwiftUI
import UIKit
import FamilyMLSCore

struct NotificationsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hande) private var p
    /// 「기록 복사」 뒤 2초 토스트.
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.notificationCount == 0 {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        // #574: 같은 계정의 새 기기가 우편함에 올린 승인 요청 — 지문 비교 시트로 승인하거나 무시(웹 `candidateCard`).
                        if !model.candidates.isEmpty {
                            Text(Strings.candidatesSectionTitle).font(.footnote.weight(.semibold)).foregroundStyle(p.inkDim)
                                .padding(.horizontal, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(model.candidates, id: \.deviceId) { candidate in
                                CandidateRow(candidate: candidate)
                            }
                        }
                        if !model.pendingInvites.isEmpty {
                            ForEach(model.pendingInvites, id: \.room) { invite in
                                LobbyInviteRow(room: invite.room, createdAt: invite.createdAt)
                            }
                        }
                        // #574: 승인한 형제 기기 초대의 포기·실패(웹 `noteRows`).
                        if !model.siblingNotes.isEmpty {
                            ForEach(model.siblingNotes) { note in
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(Strings.siblingNotesTitle).font(.system(size: 13)).foregroundStyle(p.inkDim)
                                    Text(note.text).font(.system(size: 16)).foregroundStyle(p.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button(Strings.dismissNote) { model.dismissSiblingNote(note.id) }
                                        .buttonStyle(HandeSecondaryButtonStyle())
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .handeCard()
                            }
                        }
                        Text(Strings.notifyHint).font(.system(size: 13)).foregroundStyle(p.inkDim).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .background(CampfireBackground())
            .navigationTitle(Strings.notifyTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Strings.close)
                }
                // #535: DevTools/Xcode 없이 실패 사유를 보고 — 기기·방·초대 상태 + 최근 기록을 클립보드로(비밀값 없음).
                ToolbarItem(placement: .primaryAction) {
                    Button(Strings.notifyCopyLogsShort) {
                        UIPasteboard.general.string = model.diagnosticsReport()
                        toast = Strings.notifyCopied
                    }
                    .accessibilityLabel(Strings.notifyCopyLogs)
                    .accessibilityHint(Strings.notifyCopyLogsHint)
                    .accessibilityIdentifier("notify-copy-logs")
                }
            }
            .handeToast($toast)
        }
    }

    /// 빈 상태(디자인 2차 2e): 흐린 자리 점 3개(크림 2 + 파랑 1, 60%) + 「새 알림이 없어요」 19/600 + 한 줄.
    private var emptyState: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                SeatDot(size: 8)
                SeatDot(size: 8)
                SeatDot(agent: true, size: 8)
            }
            .opacity(0.6)
            .accessibilityHidden(true)
            Text(Strings.notifyEmpty).font(.system(size: 19, weight: .semibold)).foregroundStyle(p.ink)
            Text(Strings.notifyEmptyBody).font(.system(size: 15)).foregroundStyle(p.inkDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 200)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notify-empty")
    }
}
