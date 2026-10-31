// 정지 안내·해제(§9-4 상태줄 "정지 이유"): 정지된 방마다 무엇이 일어났는지, 다음에 할 일, 운영자 보고 공유, "다시 참여 준비".
// 정지 사유를 사용자가 지우는 버튼은 없다 — 해제는 `AppModel.prepareRejoin`(상태 폐기 + 재초대 대기) 하나다.
// 내보내졌거나 닫힌 방은 「목록에서 지우기」(`AppModel.forgetRoom`, #389)로 이 기기에서 방 자체를 잊을 수 있다.
// 디자인 2차 2f(2026-10-31): 잉걸불 없는 단색 밤하늘 + 꺼진 재 점 3 + 「이 기기의 대화가 멈췄어요」 + 사유별 한 문장 + 운영자 안내.
// ⛔ 이모지 없음. 행동은 하나 — 「진단 기록 복사」(주) · 「설정 열기」(보조). 그 아래 방별 카드.
import SwiftUI
import UIKit
import FamilyMLSCore

struct HaltedRoomsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hande) private var p
    /// 「진단 기록 복사」 뒤 토스트 「복사했어요」.
    @State private var toast: String?

    private var first: RoomRecord? { model.haltedRooms.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DotsRow(color: p.ash, size: 12)
                        .padding(.top, 48)
                    if let first {
                        Text(Strings.haltedDeviceTitle)
                            .font(.system(size: 28, weight: .semibold)).foregroundStyle(p.ink)
                            .lineSpacing(4)
                            .accessibilityAddTraits(.isHeader)
                        Text(Strings.haltGuidance(first.haltedReason ?? "").what)
                            .font(.system(size: 17)).foregroundStyle(p.ink).lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Strings.haltedDeviceHint)
                            .font(.system(size: 15)).foregroundStyle(p.inkDim).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 10) {
                            Button(Strings.notifyCopyLogs) { copyReport(first) }
                                .buttonStyle(HandePrimaryButtonStyle())
                                .accessibilityIdentifier("halted-copy-report")
                            NavigationLink { SettingsView() } label: { Text(Strings.lockPreviewOpenSettings) }
                                .buttonStyle(HandeSecondaryButtonStyle())
                                .accessibilityIdentifier("halted-open-settings")
                        }
                        .padding(.top, 10)
                    } else {
                        // 모든 방의 「다시 참여 준비」가 끝났다(또는 목록에서 지웠다).
                        Text(Strings.rejoinPrepareDone).font(.system(size: 15)).foregroundStyle(p.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // 방마다 한 장 — 사유 한 문장 + 다음 할 일 + 보고·지우기·다시 참여 준비.
                    ForEach(model.haltedRooms, id: \.room) { record in
                        HaltedRoomCard(room: record.room, reason: record.haltedReason ?? "", heading: Strings.roomLabel(record.room))
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            // 이 화면만 radial 번짐 없이 밤하늘 단색(디자인 2차 2f) — 불이 꺼졌다.
            .background(p.bgTop.ignoresSafeArea())
            .navigationTitle(Strings.haltedRoomsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(Strings.close) { dismiss() } } }
            .handeToast($toast)
        }
    }

    /// 첫 정지 방의 보고(방·기기 ID·사유 토큰·시각 — 키 없음)를 클립보드로.
    private func copyReport(_ record: RoomRecord) {
        UIPasteboard.general.string = Strings.haltReport(room: record.room, device: model.deviceId, reason: record.haltedReason ?? "")
        toast = Strings.notifyCopied
    }
}

/// 한 방의 정지 안내 상자(디자인 2차 2f): 반경 16 면 5% + 선, 장작 아이콘 28 + 제목 16/600 + 본문 14 보조색 + 작은 주황 링크.
/// 방 화면(입력창 자리)과 정지 목록이 같이 쓴다. 운영자가 닫은 방은 「운영자가 이 자리를 닫았어요」, 그 밖은 사유별 `haltGuidance`.
struct HaltedRoomCard: View {
    @EnvironmentObject private var model: AppModel
    let room: RoomID
    let reason: String
    /// 「목록에서 지우기」 뒤에 부른다(방 화면은 닫힌다). 정지 목록은 목록에서 빠지는 것으로 충분하다.
    var onForgotten: (() -> Void)? = nil
    /// 정지 목록에서는 방 이름을 제목으로(어느 방인지), 방 화면에서는 사유 제목.
    var heading: String? = nil
    @State private var confirmRejoin = false
    @State private var confirmForget = false
    @State private var busy = false
    @State private var message: String?
    @Environment(\.hande) private var p

    private var guidance: Strings.HaltGuidance { Strings.haltGuidance(reason) }
    private var closed: Bool { reason == SyncHaltReason.roomClosed }
    private var title: String { heading ?? (closed ? Strings.roomClosedTitle : Strings.haltedTitle) }
    private var body1: String { closed ? Strings.roomClosedBody : guidance.what }
    private var body2: String? { closed ? nil : guidance.next }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LogIcon(size: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(p.ink)
                Text(body1).font(.system(size: 14)).foregroundStyle(p.inkDim).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let body2 {
                    Text(body2).font(.system(size: 14)).foregroundStyle(p.inkDim).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message {
                    Text(message).font(.system(size: 13)).foregroundStyle(p.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 작은 주황 링크 — 보고(공유) · 목록에서 지우기 · 다시 참여 준비. 사유 토큰은 보고 본문에만. 셋이 한 줄에 다 들어가지 않아 두 줄.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        ShareLink(item: Strings.haltReport(room: room, device: model.deviceId, reason: reason)) {
                            Text(Strings.reportToOperator)
                        }
                        if AppModel.canForget(reason: reason) {
                            Button(Strings.forgetRoomTitle) { confirmForget = true }.disabled(busy)
                        }
                    }
                    if guidance.canPrepareRejoin {
                        Button(Strings.rejoinPrepareTitle) { confirmRejoin = true }.disabled(busy)
                    }
                }
                .font(.system(size: 15))
                .foregroundStyle(p.ember)
                .tint(p.ember)
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .handeCard(fill: p.isDay ? p.surface : p.ink.opacity(0.05))
        .confirmationDialog(Strings.forgetRoomTitle, isPresented: $confirmForget, titleVisibility: .visible) {
            Button(Strings.forgetRoomTitle, role: .destructive) { Task { await forget() } }
            Button(Strings.close, role: .cancel) {}
        } message: {
            Text(Strings.forgetRoomConfirm)
        }
        .confirmationDialog(Strings.rejoinPrepareTitle, isPresented: $confirmRejoin, titleVisibility: .visible) {
            Button(Strings.rejoinPrepareTitle, role: .destructive) { Task { await prepare() } }
            Button(Strings.close, role: .cancel) {}
        } message: {
            Text(Strings.rejoinPrepareConfirm)
        }
    }

    private func forget() async {
        busy = true
        defer { busy = false }
        do {
            try await model.forgetRoom(room: room)
            onForgotten?()
        } catch {
            message = Strings.forgetRoomFailed("\(error)")
        }
    }

    private func prepare() async {
        busy = true
        defer { busy = false }
        do {
            switch try await model.prepareRejoin(room: room) {
            case .prepared: message = Strings.rejoinPrepareDone
            case .preparedWithoutPublish: message = Strings.rejoinPublishFailed
            }
        } catch AppModel.RejoinError.unsupported {
            message = Strings.haltedUnsupportedRecovery
        } catch {
            message = Strings.rejoinPrepareFailed("\(error)")
        }
    }
}
