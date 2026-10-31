// §9-5 설정: 지문·기기 ID·알림 상태(§12-D)·로그아웃(MLS 상태는 유지, 푸시 등록은 해제)·서버(#584: 현재 서버·「서버 바꾸기」).
// 디자인 2차 2e(2026-10-31): Form 대신 모닥불 배경 위 카드 — 순서 = 자주 → 드물게 → 위험.
//   서버 → 화면(밤/낮불) → 알림(「항상」일 때만 경고 상자) → 이 기기(기기 ID + 운영자용 정보 접힘) → 기기 관리 → 계정 → 위험 구역 → 정보.
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
    /// 「운영자용 정보」(로비 키·지문·릴레이) 접힘 — 숨기지 않고 접는다.
    @State private var opsOpen = false
    /// 잠금화면 경고 상자 「나중에」(이 화면에서만 접는다 — 전역 배너는 RootView 가 따로 관리).
    @State private var lockWarningLater = false
    /// 「복사」 뒤 토스트.
    @State private var toast: String?
    /// 디자인 1차: 테마 모드(RootView 가 같은 키를 읽어 팔레트·컬러 스킴을 바꾼다).
    @AppStorage(HandeThemeMode.storageKey) private var themeRaw = HandeThemeMode.night.rawValue
    @Environment(\.hande) private var p

    private var theme: HandeThemeMode { HandeThemeMode.from(themeRaw) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                serverSection
                displaySection
                notificationsSection
                thisDeviceSection
                devicesSection
                accountSection
                dangerSection
                aboutSection
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(CampfireBackground())
        .navigationTitle(Strings.settingsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshLockScreenPreview() }
        .handeToast($toast)
        .confirmationDialog(Strings.wipeTitle, isPresented: $confirmWipe, titleVisibility: .visible) {
            Button(Strings.wipeConfirmButton, role: .destructive) { Task { await wipe() } }
            Button(Strings.close, role: .cancel) {}
        } message: {
            Text(Strings.wipeWarning)
        }
        .confirmationDialog(Strings.serverChange, isPresented: $confirmServerChange, titleVisibility: .visible) {
            Button(Strings.serverChangeConfirm, role: .destructive) { Task { await changeServer() } }
            Button(Strings.close, role: .cancel) {}
        } message: {
            Text(Strings.serverChangeWarning)
        }
    }

    // MARK: 서버 — 이름 17 + 모노 주소 13 + 「바꾸기」(#584: 로그아웃 뒤 서버 선택 화면; 이 서버의 로컬 데이터는 스코프에 남는다).
    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(Strings.serverSection)
            SectionCard {
                SectionRow(divider: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.server?.name ?? Strings.serverNoName).font(.system(size: 17)).foregroundStyle(p.ink)
                        if let server = model.server {
                            Text(server.baseURL.host ?? server.baseURL.absoluteString)
                                .font(.system(size: 13, design: .monospaced)).foregroundStyle(p.inkDim)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(Strings.serverChangeShort) { confirmServerChange = true }
                        .buttonStyle(.borderless)
                        .font(.system(size: 15)).foregroundStyle(p.ember).tint(p.ember)
                        .disabled(serverChangeBusy)
                        .accessibilityLabel(Strings.serverChange)
                        .accessibilityIdentifier("settings-change-server")
                }
            }
        }
    }

    // MARK: 화면 — 밤(기본·고정) / 낮불(e-ink·밝은 곳). 밤을 밝게 뒤집은 라이트 모드가 아니라 별도 고대비 설계.
    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(Strings.themeSection)
            SectionCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        themeChip(.night, label: Strings.themeChipNight)
                        themeChip(.day, label: Strings.themeChipDay)
                    }
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 12).fill(p.ink.opacity(0.05)))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Strings.themeLabel)
                    .accessibilityIdentifier("settings-theme")
                    Text(theme == .day ? Strings.themeDayHint : Strings.themeNightHint)
                        .font(.system(size: 14)).foregroundStyle(p.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private func themeChip(_ mode: HandeThemeMode, label: String) -> some View {
        let on = theme == mode
        return Button { themeRaw = mode.rawValue } label: {
            Text(label)
                .font(.system(size: 15, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? p.onEmber : p.inkDim)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(on ? p.ember : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(on && p.isDay ? p.stroke : Color.clear, lineWidth: p.lineWidth))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : AccessibilityTraits())
        .accessibilityIdentifier("settings-theme-\(mode.rawValue)")
    }

    // MARK: 알림 — 새 메시지 알림 · 잠금화면 미리보기(#520: 「항상」이면 붉은 값 + 아래 경고 상자 → 설정 앱).
    private var notificationsSection: some View {
        let warning = model.lockScreenPreview.needsWarning
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(Strings.notifications)
            SectionCard {
                SectionRow(divider: false) {
                    Text(Strings.pushLabel).font(.system(size: 17)).foregroundStyle(p.ink)
                    Spacer(minLength: 8)
                    Text(Self.describe(model.pushStatus)).font(.system(size: 15)).foregroundStyle(p.inkDim)
                        .multilineTextAlignment(.trailing)
                }
                SectionRow {
                    Text(Strings.lockPreviewLabel).font(.system(size: 17)).foregroundStyle(p.ink)
                    Spacer(minLength: 8)
                    Text(Strings.lockPreviewShort(model.lockScreenPreview)).font(.system(size: 15))
                        .foregroundStyle(warning ? p.warn : p.inkDim)
                        .accessibilityLabel(Strings.lockPreview(model.lockScreenPreview))
                }
            }
            if warning && !lockWarningLater {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Strings.lockPreviewWarningTitle).font(.system(size: 16, weight: .semibold)).foregroundStyle(p.ink)
                    Text(Strings.lockPreviewWarningBodyShort).font(.system(size: 14)).foregroundStyle(p.inkDim).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(Strings.lockPreviewOpenSettings) { LockPreviewWarningBanner.openNotificationSettings() }
                            .buttonStyle(HandePrimaryButtonStyle())
                            .accessibilityIdentifier("settings-lock-preview-open")
                        Button(Strings.lockPreviewLater) { withAnimation { lockWarningLater = true } }
                            .buttonStyle(HandeSecondaryButtonStyle())
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .handeCard(fill: p.warn.opacity(0.07), stroke: p.warn.opacity(0.55))
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .accessibilityIdentifier("settings-lock-preview-warning")
            }
        }
    }

    // MARK: 이 기기 — 기기 ID + 복사 · 「운영자용 정보」(지문·로비 키·릴레이) 접힘.
    private var thisDeviceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(Strings.settingsThisDevice)
            SectionCard {
                SectionRow(divider: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Strings.deviceIdLabel).font(.system(size: 13)).foregroundStyle(p.inkDim)
                        Text(model.deviceId).font(.system(size: 15, design: .monospaced)).foregroundStyle(p.ink)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button(Strings.copyAction) { copy(model.deviceId) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 15)).foregroundStyle(p.ember).tint(p.ember)
                        .accessibilityLabel("\(Strings.deviceIdLabel) \(Strings.copyAction)")
                        .accessibilityIdentifier("settings-copy-device-id")
                }
                Button { withAnimation(.easeOut(duration: 0.15)) { opsOpen.toggle() } } label: {
                    SectionRow {
                        Text(Strings.operatorInfo).font(.system(size: 15)).foregroundStyle(p.inkDim)
                        Spacer(minLength: 8)
                        Image(systemName: opsOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.inkDim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(opsOpen ? [.isSelected] : [])
                .accessibilityIdentifier("settings-operator-info")
                if opsOpen {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(Strings.fingerprintLabel)\n\(SelfService.fingerprintGroups(model.fingerprint))")
                            Text("\(Strings.lobbyKeysLabel)  \(Strings.lobbyKeys(model.lobbyLive))")
                            Text("\(Strings.relayLabel)  \(model.server?.baseURL.host ?? model.server?.baseURL.absoluteString ?? "-")")
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(p.ink)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .handeCard(radius: 10, fill: p.isDay ? p.surface : Color.black.opacity(0.25))
                        Text(Strings.lobbyHintPlain).font(.system(size: 13)).foregroundStyle(p.inkDim).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                    .accessibilityIdentifier("settings-operator-info-body")
                }
            }
        }
    }

    // MARK: 기기 관리 — #574 「내 기기」: 체인의 내 기기 목록·등록 기기 지정/해제·승인 대기 새 기기(DevicesView).
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(Strings.settingsDeviceManage)
            SectionCard {
                NavigationLink { DevicesView() } label: {
                    SectionRow(divider: false) {
                        Text(Strings.devicesTitle).font(.system(size: 17)).foregroundStyle(p.ink)
                        Spacer(minLength: 8)
                        if !model.candidates.isEmpty { InviteCountBadge(count: model.candidates.count).offset(x: -8, y: 6) }
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.inkDim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-devices")
            }
        }
    }

    // MARK: 계정 — 로그아웃(세션만; 암호화 상태는 유지).
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(Strings.settingsAccount)
            SectionCard {
                Button { _ = model.logout() } label: {
                    SectionRow(divider: false) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Strings.logout).font(.system(size: 17)).foregroundStyle(p.ink)
                            Text(Strings.logoutHintPlain).font(.system(size: 13)).foregroundStyle(p.inkDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-logout")
            }
        }
    }

    // MARK: 위험 구역 — 「이 기기의 키와 대화가 모두 지워집니다」 + 「이 기기 지우기」 하나만(위험 버튼). 결과는 상자 안 한 줄.
    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(Strings.settingsDanger, color: p.warn)
            VStack(alignment: .leading, spacing: 10) {
                Text(Strings.wipeDangerBody).font(.system(size: 14)).foregroundStyle(p.inkDim).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Strings.wipeTitle) { confirmWipe = true }
                    .buttonStyle(HandeDangerButtonStyle())
                    .disabled(wipeBusy)
                    .accessibilityIdentifier("settings-wipe-device")
                if let wipeMessage {
                    Text(wipeMessage).font(.system(size: 13)).foregroundStyle(p.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Hande.radiusM).stroke(p.warn.opacity(0.5), lineWidth: 1.5))
            .padding(.horizontal, 16)
        }
    }

    // MARK: 정보 — #584 PR 4 정책 링크(App Store 5.1.1(v)·Play 정책; Link 는 Safari 로 연다) + 앱 버전(project.yml MARKETING_VERSION / CURRENT_PROJECT_VERSION).
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(Strings.settingsAbout)
            SectionCard {
                Link(destination: PolicyLinks.privacy) { linkRow(Strings.privacyPolicy, divider: false) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-privacy")
                Link(destination: PolicyLinks.deleteAccount) { linkRow(Strings.deleteDataGuide) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Strings.deleteAccount)
                    .accessibilityIdentifier("settings-delete-account")
                SectionRow {
                    Text(Strings.versionShort).font(.system(size: 17)).foregroundStyle(p.ink)
                    Spacer(minLength: 8)
                    Text(Self.appVersionLine(Bundle.main)).font(.system(size: 14, design: .monospaced)).foregroundStyle(p.inkDim)
                        .accessibilityLabel("\(Strings.versionLabel) \(Self.appVersionLine(Bundle.main))")
                }
            }
        }
    }

    private func linkRow(_ title: String, divider: Bool = true) -> some View {
        SectionRow(divider: divider) {
            Text(title).font(.system(size: 17)).foregroundStyle(p.ink)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.inkDim)
        }
        .contentShape(Rectangle())
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        toast = Strings.notifyCopied
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

/// #520 전역 배너(RootView 오버레이): 미리보기 「항상」 경고 + 설정 열기 / 나중에. 불빛 18% 면(테마 토큰).
struct LockPreviewWarningBanner: View {
    let onDismiss: () -> Void
    @Environment(\.hande) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.lockPreviewWarningTitle).font(.headline).foregroundStyle(p.ink)
            Text(Strings.lockPreviewWarningBody).font(.footnote).foregroundStyle(p.inkDim)
            HStack(spacing: 16) {
                Button(Strings.lockPreviewOpenSettings) { Self.openNotificationSettings() }.font(.footnote.bold())
                Button(Strings.lockPreviewLater, action: onDismiss).font(.footnote)
            }
            .foregroundStyle(p.ember)
            .tint(p.ember)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.ember.opacity(0.18))
    }

    /// 이 앱의 알림 설정 화면(iOS 16+). 열 수 없으면 아무것도 하지 않는다.
    @MainActor
    static func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// 전역 배너(RootView 오버레이): 사유 한 줄 + "자세히" → 정지된 방 목록(HaltedRoomsView: 안내·보고·다시 참여 준비). 붉은 잉걸 15% 면.
struct HaltedBanner: View {
    let reason: String
    @State private var showDetails = false
    @Environment(\.hande) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.haltedTitle).font(.headline).foregroundStyle(p.ink)
            Text(Strings.haltBannerBody(reason)).font(.footnote).foregroundStyle(p.inkDim)
            Button(Strings.haltedDetails) { showDetails = true }.font(.footnote.bold()).foregroundStyle(p.ember).tint(p.ember)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.warn.opacity(0.15))
        .sheet(isPresented: $showDetails) { HaltedRoomsView() }
    }
}
