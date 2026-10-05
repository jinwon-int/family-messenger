// §9-5 설정: 지문·기기 ID·알림(자리)·로그아웃(MLS 상태는 유지).
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
                Toggle(Strings.notifications, isOn: .constant(false)).disabled(true)
            }
            Section(footer: Text(Strings.logoutHint)) {
                Button(Strings.logout, role: .destructive) { model.logout() }
            }
        }
        .navigationTitle(Strings.settingsTitle)
    }
}

struct HaltedBanner: View {
    let reason: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.haltedTitle).font(.headline)
            Text(Strings.haltedBody(reason)).font(.footnote)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.15))
    }
}
