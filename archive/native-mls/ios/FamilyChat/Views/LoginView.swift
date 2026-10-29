// §12-C A 가족 로그인: 「Google 계정으로 로그인」→ 시스템 브라우저 시트(AppLogin.swift)에서 Cloudflare Access 로그인 →
// 릴레이가 고정 스킴으로 돌려준 세션으로 연결한다. 세션 값 붙여넣기(뼈대)는 운영자용 폴백으로 접어 둔다 — 가족 흐름에 쓰지 않는다.
import SwiftUI
import FamilyMLSCore
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var busy = false
    @State private var failure: String?
    @State private var manualExpanded = false
    @State private var value = ""
    #if canImport(AuthenticationServices) && canImport(UIKit)
    @State private var session = AccessLoginSession()
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(Strings.loginHint)) {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Label(Strings.loginGoogle, systemImage: "person.crop.circle")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || model.relayURL == nil)
                    if model.relayURL == nil {
                        Text(Strings.relayNotConfigured).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let failure {
                        Text(failure).font(.footnote).foregroundStyle(.red)
                    }
                }
                Section {
                    DisclosureGroup(Strings.loginManualTitle, isExpanded: $manualExpanded) {
                        SecureField(Strings.loginField, text: $value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(Strings.loginButton) {
                            model.login(.accessCookie(value.trimmingCharacters(in: .whitespacesAndNewlines)))
                            value = ""
                        }
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text(Strings.loginManualHint).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                // #584: 현재 서버 + 「다른 서버 선택」(빌드 기본 서버가 자동으로 잡힌 설치의 출구)
                ServerSwitchSection()
            }
            .navigationTitle(Strings.loginTitle)
        }
    }

    @MainActor
    private func signIn() async {
        guard let relayURL = model.relayURL else { failure = Strings.relayNotConfigured; return }
        busy = true
        failure = nil
        defer { busy = false }
        #if canImport(AuthenticationServices) && canImport(UIKit)
        do {
            let credential = try await session.run(relayURL: relayURL)
            model.login(credential)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // 사용자가 시트를 닫았다 — 오류가 아니다.
        } catch {
            failure = Strings.loginFailure(error)
        }
        #else
        failure = Strings.loginFailure(AppLogin.Failure.cannotStart)
        #endif
    }
}
