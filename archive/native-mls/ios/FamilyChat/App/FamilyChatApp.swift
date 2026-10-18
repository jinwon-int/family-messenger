// 한데(코드명 FamilyChat) iOS(독자 E2EE) — 앱 진입점. 파이널라이저 소유(CONTRACTS.md §0). 화면 정보구조는 #271 §9.
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
    private static let openingLimitNanoseconds: UInt64 = 8_000_000_000

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                OpeningView()
            case .needsEnrollment where !model.settled && !openingExpired:
                OpeningView()
            case .needsActor:
                ActorSetupView()
            case .needsLogin:
                LoginView()
            case .needsEnrollment:
                EnrollView()
            case .ready, .halted:
                NavigationStack(path: $navigator.path) { RoomListView() }
                    .environmentObject(navigator)
                    .environmentObject(LocalPrefs.shared)
            case .fatal(let reason):
                FatalView(reason: reason)
            }
        }
        .overlay(alignment: .top) {
            if case .halted(let reason) = model.phase { HaltedBanner(reason: reason) }
        }
        .animation(.easeOut(duration: 0.35), value: model.settled)
        .task {
            try? await Task.sleep(nanoseconds: Self.openingLimitNanoseconds)
            openingExpired = true
        }
        // #405 P2: 밤 테마 고정(오너 결정) + 불빛 강조색.
        .preferredColorScheme(.dark)
        .tint(Hande.ember)
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
