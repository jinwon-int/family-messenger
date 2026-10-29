// §9-5 설정: 지문·기기 ID·알림 상태(§12-D)·로그아웃(MLS 상태는 유지, 푸시 등록은 해제)·서버(#584: 현재 서버·「서버 바꾸기」).
import SwiftUI
import UIKit
import FamilyMLSCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmWipe = false
    @State private var wipeBusy = false
    @State private var wipeMessage: String?
    @State private var confirmServerChange = false
    @State private var serverChangeBusy = false

    var body: some View {
        Form {
            Section {
                LabeledContent(Strings.fingerprintLabel) {
                    Text(model.fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                }
                LabeledContent(Strings.deviceIdLabel) { Text(model.deviceId).font(.footnote) }
                // #584: 앱 버전(스토어 심사·문의 때 식별). 값은 빌드 설정 MARKETING_VERSION / CURRENT_PROJECT_VERSION(project.yml).
                LabeledContent(Strings.versionLabel) { Text(Self.appVersionLine(Bundle.main)).font(.footnote) }
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
            // #584: 서버 — 현재 서버(이름·주소·찾은 방법) + 「서버 바꾸기」(로그아웃 뒤 서버 선택 화면; 이 서버의 로컬 데이터는 스코프에 남는다).
            Section(header: Text(Strings.serverSection), footer: Text(Strings.serverChangeWarning)) {
                if let server = model.server {
                    LabeledContent(Strings.serverNameLabel) { Text(server.name ?? Strings.serverNoName).font(.footnote) }
                    LabeledContent(Strings.serverURLLabel) {
                        Text(server.baseURL.absoluteString).font(.footnote).textSelection(.enabled)
                    }
                    Text(Strings.serverVia(server.discoveredVia)).font(.footnote).foregroundStyle(.secondary)
                }
                Button(Strings.serverChange, role: .destructive) { confirmServerChange = true }
                    .disabled(serverChangeBusy)
                    .accessibilityIdentifier("settings-change-server")
                    .confirmationDialog(Strings.serverChange, isPresented: $confirmServerChange, titleVisibility: .visible) {
                        Button(Strings.serverChangeConfirm, role: .destructive) { Task { await changeServer() } }
                        Button(Strings.close, role: .cancel) {}
                    } message: {
                        Text(Strings.serverChangeWarning)
                    }
            }
            // #584 PR 4: 정책 링크(App Store 5.1.1(v)·Play 정책 — 앱 안에서 열리는 개인정보처리방침·계정 삭제 안내). Link 는 Safari 로 연다.
            // 「이 기기 지우기」(아래)가 앱 내 삭제 경로이고, 서버 쪽 기록은 「계정 및 데이터 삭제」 안내로 — docs/hande/delete-account.md 와 같은 구성.
            Section(header: Text(Strings.policySection), footer: Text(Strings.policyHint)) {
                Link(destination: PolicyLinks.privacy) { Label(Strings.privacyPolicy, systemImage: "hand.raised") }
                    .accessibilityIdentifier("settings-privacy")
                Link(destination: PolicyLinks.deleteAccount) { Label(Strings.deleteAccount, systemImage: "person.crop.circle.badge.xmark") }
                    .accessibilityIdentifier("settings-delete-account")
            }
            Section(footer: Text(wipeMessage ?? Strings.wipeHint)) {
                Button(Strings.wipeTitle, role: .destructive) { confirmWipe = true }
                    .disabled(wipeBusy)
                    .accessibilityIdentifier("settings-wipe-device")
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

    private func changeServer() async {
        serverChangeBusy = true
        defer { serverChangeBusy = false }
        await model.changeServer()
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

    /// `CFBundleShortVersionString (CFBundleVersion)` — 둘 다 없으면 "?"(무서명 로컬 빌드).
    static func appVersionLine(_ bundle: Bundle) -> String {
        Strings.appVersion(bundle.familyChatValue("CFBundleShortVersionString") ?? "?",
                           bundle.familyChatValue("CFBundleVersion") ?? "?")
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
