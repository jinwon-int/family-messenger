// 패밀리챗 iOS(독자 E2EE) — 앱 진입점. 파이널라이저 소유(CONTRACTS.md §0). 화면 정보구조는 #271 §9.
// 의존성은 `Dependencies.live()`(L1 파일 저장소 + L3 릴레이 동기화 + ios-ffi 엔진, LiveDependencies.swift).
// 화면이 떠 있는 동안 4초 포그라운드 폴링(CONTRACTS §2.2), 백그라운드 wake 는 푸시(§12-D).
import SwiftUI
import FamilyMLSCore

@main
struct FamilyChatApp: App {
    @StateObject private var model = AppModel(dependencies: .live())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task {
                    await model.bootstrap()
                    await model.runForeground()
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                ProgressView(Strings.starting)
            case .needsLogin:
                LoginView()
            case .needsEnrollment:
                EnrollView()
            case .ready, .halted:
                NavigationStack { RoomListView() }
            case .fatal(let reason):
                FatalView(reason: reason)
            }
        }
        .overlay(alignment: .top) {
            if case .halted(let reason) = model.phase { HaltedBanner(reason: reason) }
        }
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
