// §9-5 설정: 지문·기기 ID·알림 상태(§12-D)·로그아웃(MLS 상태는 유지, 푸시 등록은 해제).
import SwiftUI
import UIKit
import FamilyMLSCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmWipe = false
    @State private var wipeBusy = false
    @State private var wipeMessage: String?

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
                // #520: 측정 때 함께 기록할 값(기기 설정 의존). 「항상」이면 설정 앱으로 보낸다.
                LabeledContent(Strings.lockPreviewLabel) { Text(Strings.lockPreview(model.lockScreenPreview)).font(.footnote) }
                if model.lockScreenPreview.needsWarning {
                    Button(Strings.lockPreviewOpenSettings) { LockPreviewWarningBanner.openNotificationSettings() }
                }
            }
            .task { await model.refreshLockScreenPreview() }
            Section(footer: Text(Strings.lobbyHint)) {
                LabeledContent(Strings.lobbyKeysLabel) { Text(Strings.lobbyKeys(model.lobbyLive)).font(.footnote) }
            }
            // #574: 「내 기기」 — 체인의 내 기기 목록·등록 기기(registrar) 지정/해제, 승인 대기 새 기기.
            Section {
                NavigationLink { DevicesView() } label: {
                    HStack {
                        Label(Strings.devicesTitle, systemImage: "iphone.gen3")
                        Spacer()
                        if !model.candidates.isEmpty { InviteCountBadge(count: model.candidates.count) }
                    }
                }
                .accessibilityIdentifier("settings-devices")
            }
            Section(footer: Text(Strings.logoutHint)) {
                Button(Strings.logout, role: .destructive) { model.logout() }
            }
            Section(footer: Text(wipeMessage ?? Strings.wipeHint)) {
                Button(Strings.wipeTitle, role: .destructive) { confirmWipe = true }
                    .disabled(wipeBusy)
            }
        }
        .navigationTitle(Strings.settingsTitle)
        .confirmationDialog(Strings.wipeTitle, isPresented: $confirmWipe, titleVisibility: .visible) {
            Button(Strings.wipeConfirmButton, role: .destructive) { Task { await wipe() } }
            Button(Strings.close, role: .cancel) {}
        } message: {
            Text(Strings.wipeWarning)
        }
    }

    private func wipe() async {
        wipeBusy = true
        defer { wipeBusy = false }
        do {
            try await model.wipeDevice()
            wipeMessage = Strings.wipeDone
        } catch {
            wipeMessage = Strings.wipeFailed("\(error)")
        }
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

/// #520 전역 배너(RootView 오버레이): 미리보기 「항상」 경고 + 설정 열기 / 나중에.
struct LockPreviewWarningBanner: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.lockPreviewWarningTitle).font(.headline)
            Text(Strings.lockPreviewWarningBody).font(.footnote)
            HStack(spacing: 16) {
                Button(Strings.lockPreviewOpenSettings) { Self.openNotificationSettings() }.font(.footnote.bold())
                Button(Strings.lockPreviewLater, action: onDismiss).font(.footnote)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.18))
    }

    /// 이 앱의 알림 설정 화면(iOS 16+). 열 수 없으면 아무것도 하지 않는다.
    @MainActor
    static func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// 전역 배너(RootView 오버레이): 사유 한 줄 + "자세히" → 정지된 방 목록(HaltedRoomsView: 안내·보고·다시 참여 준비).
struct HaltedBanner: View {
    let reason: String
    @State private var showDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.haltedTitle).font(.headline)
            Text(Strings.haltBannerBody(reason)).font(.footnote)
            Button(Strings.haltedDetails) { showDetails = true }.font(.footnote.bold())
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.15))
        .sheet(isPresented: $showDetails) { HaltedRoomsView() }
    }
}
