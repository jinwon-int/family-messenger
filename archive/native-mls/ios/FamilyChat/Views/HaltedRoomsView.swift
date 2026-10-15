// ⛔ 정지 안내·해제(§9-4 상태줄 "정지 이유"): 정지된 방마다 무엇이 일어났는지, 다음에 할 일, 운영자 보고 공유, "다시 참여 준비".
// 정지 사유를 사용자가 지우는 버튼은 없다 — 해제는 `AppModel.prepareRejoin`(상태 폐기 + 재초대 대기) 하나다.
import SwiftUI
import FamilyMLSCore

struct HaltedRoomsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.haltedRooms.isEmpty {
                    Text(Strings.rejoinPrepareDone).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.haltedRooms, id: \.room) { record in
                    Section(record.room) {
                        HaltedRoomCard(room: record.room, reason: record.haltedReason ?? "")
                    }
                }
            }
            .navigationTitle(Strings.haltedRoomsTitle)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(Strings.close) { dismiss() } } }
        }
    }
}

/// 한 방의 정지 안내 + 행동 2개. 방 화면과 정지 목록이 같이 쓴다.
struct HaltedRoomCard: View {
    @EnvironmentObject private var model: AppModel
    let room: RoomID
    let reason: String
    @State private var confirmRejoin = false
    @State private var busy = false
    @State private var message: String?

    private var guidance: Strings.HaltGuidance { Strings.haltGuidance(reason) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.haltedTitle).font(.headline)
            Text(guidance.what).font(.footnote)
            Text(guidance.next).font(.footnote).foregroundStyle(.secondary)
            Text("\(Strings.haltedReasonLabel): \(reason)").font(.caption.monospaced()).foregroundStyle(.secondary)
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            HStack {
                ShareLink(item: Strings.haltReport(room: room, device: model.deviceId, reason: reason)) {
                    Label(Strings.reportToOperator, systemImage: "square.and.arrow.up")
                }
                if guidance.canPrepareRejoin {
                    Spacer()
                    Button(Strings.rejoinPrepareTitle, role: .destructive) { confirmRejoin = true }
                        .disabled(busy)
                }
            }
            .font(.footnote)
        }
        .confirmationDialog(Strings.rejoinPrepareTitle, isPresented: $confirmRejoin, titleVisibility: .visible) {
            Button(Strings.rejoinPrepareTitle, role: .destructive) { Task { await prepare() } }
            Button(Strings.close, role: .cancel) {}
        } message: {
            Text(Strings.rejoinPrepareConfirm)
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
