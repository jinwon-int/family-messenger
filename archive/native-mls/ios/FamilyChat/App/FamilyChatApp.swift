// 한데(코드명 FamilyChat) iOS(독자 E2EE) — 앱 진입점. 파이널라이저 소유(CONTRACTS.md §0). 화면 정보구조는 #271 §9.
// #584: 첫 화면은 서버 선택(`.needsServer`, ServerSelectView) — 저장된 선택도 빌드 기본값도 없을 때. 읽음 위치·방 순서(`LocalPrefs`)는
// 모델이 서버 스코프별로 소유한다(`model.localPrefs`).
// 의존성은 `Dependencies.live()`(L1 파일 저장소 + L3 릴레이 동기화 + ios-ffi 엔진, LiveDependencies.swift).
// 화면이 떠 있는 동안 4초 포그라운드 폴링(CONTRACTS §2.2), 백그라운드 wake 는 푸시(§12-D, NSE).
// 모델은 AppDelegate 가 소유한다 — APNs 토큰·알림 콜백이 UIKit 델리게이트로만 오기 때문(AppDelegate.swift).
import SwiftUI
import FamilyMLSCore

@main
struct FamilyChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appDelegate.model)
                .task {
                    // #520: 첫 활성화는 scenePhase 변화가 없어 여기서 읽는다(전면 복귀는 foregrounded 가 다시 읽는다).
                    await appDelegate.model.refreshLockScreenPreview()
                    await appDelegate.model.bootstrap()
                    await appDelegate.model.runForeground()
                }
                // 전면 복귀(#380 로비 보충 시점) — 첫 활성화는 bootstrap 뒤 첫 바퀴가 맡는다(lobbyCheckDue 초기값 true).
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await appDelegate.model.foregrounded() } }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    /// #405 P3: 방 전환(PageUp/PageDown)·목록 복귀(Home)를 위해 이동 경로를 쥔다.
    @StateObject private var navigator = Navigator()
    /// #414: 첫 동기화가 오래 걸려도(오프라인 등) 오프닝에 갇히지 않게 — 이 시간이 지나면 실제 상태를 보인다.
    @State private var openingExpired = false
    /// #520 경고 배너를 「나중에」로 닫았다(이 실행 동안만 — 다음 실행에 설정이 그대로면 다시 보인다).
    @State private var previewWarningDismissed = false
    /// 디자인 2차-A(§A2 ④): 이 실행에서 온보딩(서버 선택·이름)을 거쳤다 — 그 뒤의 `.starting`(이름 확정 → bootstrap 의 키 생성)과 첫 동기화
    /// 대기는 오프닝 그림 대신 「불을 피우는 중…」(KindlingView). 저장된 설치의 차가운 시작은 그대로 오프닝.
    @State private var sawOnboarding = false
    /// 디자인 1차: 테마 모드(설정 「화면」). 밤이 기본·고정, 낮불은 e-ink·밝은 곳용 고대비 — 기기 표시 설정이라 서버 스코프 밖.
    @AppStorage(HandeThemeMode.storageKey) private var themeRaw = HandeThemeMode.night.rawValue
    private static let openingLimitNanoseconds: UInt64 = 8_000_000_000

    private var theme: HandeThemeMode { HandeThemeMode.from(themeRaw) }

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                if sawOnboarding { KindlingView() } else { OpeningView() }
            case .needsEnrollment where !model.settled && !openingExpired:
                if sawOnboarding { KindlingView() } else { OpeningView() }
            case .needsServer:
                ServerSelectView()
            case .needsActor:
                ActorSetupView()
            case .needsLogin:
                LoginView()
            case .needsEnrollment:
                EnrollView()
            case .ready, .halted:
                NavigationStack(path: $navigator.path) { RoomListView() }
                    .environmentObject(navigator)
                    .environmentObject(model.localPrefs)
            case .fatal(let reason):
                FatalView(reason: reason)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                if case .halted(let reason) = model.phase { HaltedBanner(reason: reason) }
                // #520: 미리보기 「항상」이면 잠금화면에 본문이 보인다 — 방 목록이 보이는 동안 경고(「나중에」는 이 실행에서만 닫힘).
                if canShowRooms, model.lockScreenPreview.needsWarning, !previewWarningDismissed {
                    LockPreviewWarningBanner { previewWarningDismissed = true }
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: model.settled)
        // 배너 탭(§12-D): 알림의 방이 아는 방이고 목록을 보일 수 있으면 그 방으로. 로그인·첫 동기화 전이면 준비된 뒤에.
        .onChange(of: model.requestedRoom) { _ in openRequestedRoom() }
        .onChange(of: model.rooms) { _ in openRequestedRoom() }
        .onChange(of: model.phase) { phase in
            if phase == .needsServer || phase == .needsActor { sawOnboarding = true }
            openRequestedRoom()
        }
        // #571 B: 릴레이가 아는 같은 사람(actor)의 읽음 위치를 이 기기 값에 합쳐 둔다(웹 app.js mergeRelayRead) — `markRead` 는 줄어들지 않는다.
        .onChange(of: model.relayReadSeq) { relay in
            for (room, seq) in relay { model.localPrefs.markRead(room, seq: seq) }
        }
        .task {
            try? await Task.sleep(nanoseconds: Self.openingLimitNanoseconds)
            openingExpired = true
        }
        // #405 P2: 밤 테마 고정(오너 결정) + 불빛 강조색. 디자인 1차: 낮불을 고르면 밝은 스킴 + 낮불 팔레트(시스템 라이트 모드는 따르지 않는다).
        .environment(\.hande, theme.palette)
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.palette.ember)
    }
}

extension RootView {
    private var canShowRooms: Bool {
        switch model.phase { case .ready, .halted: return true; default: return false }
    }

    private func openRequestedRoom() {
        guard let room = NotificationRoute.target(requested: model.requestedRoom, knownRooms: model.rooms.map(\.room), ready: canShowRooms)
        else { return }
        model.consumeRequestedRoom()
        navigator.open(room)
    }
}

struct FatalView: View {
    let reason: String
    var body: some View {
        VStack(spacing: 12) {
            Text(Strings.fatalTitle).font(.headline)
            Text(reason).font(.footnote).multilineTextAlignment(.center)
        }.padding()
    }
}
