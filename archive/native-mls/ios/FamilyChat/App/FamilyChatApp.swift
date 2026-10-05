// 패밀리챗 iOS(독자 E2EE) — 앱 진입점. 파이널라이저 소유(CONTRACTS.md §0). 화면 정보구조는 #271 §9.
// 이 단계(뼈대)는 네트워크·영속 없이 Core 의 InMemory 스토어 + 실제 FFI 엔진으로 상태 전이와 화면만 잇는다.
// L1(파일 스토어)·L3(릴레이 동기화)이 머지되면 `AppModel` 의 의존성만 바꾼다.
import SwiftUI
import FamilyMLSCore

@main
struct FamilyChatApp: App {
    @StateObject private var model = AppModel(dependencies: .live())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.bootstrap() }
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
