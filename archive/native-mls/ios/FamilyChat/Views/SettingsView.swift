// §9-5 설정: 지문·기기 ID·알림 상태(§12-D)·로그아웃(MLS 상태는 유지, 푸시 등록은 해제).
import SwiftUI
import FamilyMLSCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent(Strings.fingerprintLabel) {
                    Text(model.fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                }
                LabeledContent(Strings.deviceIdLabel) { Text(model.deviceId).font(.footnote) }
            }
            Section(footer: Text(Strings.notificationsHint)) {
                LabeledContent(Strings.notifications) { Text(Self.describe(model.pushStatus)).font(.footnote) }
            }
            Section(footer: Text(Strings.logoutHint)) {
                Button(Strings.logout, role: .destructive) { model.logout() }
            }
        }
        .navigationTitle(Strings.settingsTitle)
    }

    static func describe(_ status: PushRegistrar.Status) -> String {
        switch status {
        case .off: return Strings.pushOff
        case .unavailable(let reason): return reason
        case .waitingForToken: return Strings.pushWaiting
        case .registered: return Strings.pushRegistered
        case .failed(let reason): return Strings.pushFailed(reason)
        }
    }
}

/// 전역 배너(RootView 오버레이): 사유 한 줄 + "자세히" → 정지된 방 목록(HaltedRoomsView: 안내·보고·다시 참여 준비).
struct HaltedBanner: View {
    let reason: String
    @State private var showDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.haltedTitle).font(.headline)
            Text(Strings.haltedBody(reason)).font(.footnote)
            Button(Strings.haltedDetails) { showDetails = true }.font(.footnote.bold())
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.15))
        .sheet(isPresented: $showDetails) { HaltedRoomsView() }
    }
}
