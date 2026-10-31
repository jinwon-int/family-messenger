// §12-C A 가족 로그인: 「Google 계정으로 로그인」→ 시스템 브라우저 시트(AppLogin.swift)에서 Cloudflare Access 로그인 →
// 릴레이가 고정 스킴으로 돌려준 세션으로 연결한다. 세션 값 붙여넣기(뼈대)는 운영자용 폴백으로 접어 둔다 — 가족 흐름에 쓰지 않는다.
// 디자인 2차-A(§A2 ③): 진행 막대 3/4 + 제목 + 1줄 「운영자가 허용해 둔 Google 계정으로 들어갑니다.」 + 「자세히」(Safari·비밀번호 안내) +
// 크림 면 주 버튼(이 화면의 할 일은 하나라 주황 대신 크림). 운영자용 「직접 입력」은 맨 아래 접힌 행 — 숨기지 않되 가족 눈에 덜 띄게.
import SwiftUI
import FamilyMLSCore
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hande) private var p
    @State private var busy = false
    @State private var failure: String?
    @State private var manualExpanded = false
    @State private var value = ""
    #if canImport(AuthenticationServices) && canImport(UIKit)
    @State private var session = AccessLoginSession()
    #endif

    private var trimmedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        OnboardingScreen(step: 3, title: Strings.loginTitle) {
            DetailDisclosure(hint: Strings.loginStepLine, hintSize: 16, text: Strings.loginStepDetail)

            Button {
                Task { await signIn() }
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(p.onEmber) }
                    Text(Strings.loginGoogle)
                }
            }
            .buttonStyle(HandeCreamButtonStyle())
            .disabled(busy || model.relayURL == nil)
            .padding(.top, 8)

            if model.relayURL == nil {
                Text(Strings.relayNotConfigured)
                    .font(.system(size: 14))
                    .foregroundStyle(p.inkDim)
                    .padding(.horizontal, 4)
            }
            if let failure {
                Text(failure)
                    .font(.system(size: 14))
                    .foregroundStyle(p.warn)
                    .padding(.horizontal, 4)
            }
            // #584: 현재 서버 + 「다른 서버 선택」(빌드 기본 서버가 자동으로 잡힌 설치의 출구)
            ServerSwitchSection()
        } footer: {
            manualEntry
        }
    }

    /// 운영자용 세션 값 입력 — 접힌 행 카드. 펼치면 SecureField + 「연결」(보조) + 안내.
    private var manualEntry: some View {
        HandeCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { manualExpanded.toggle() }
                } label: {
                    HStack {
                        Text(Strings.loginManualTitle)
                            .font(.system(size: 15))
                            .foregroundStyle(p.inkDim)
                        Spacer()
                        Image(systemName: manualExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(p.inkDim)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(manualExpanded ? [.isSelected] : [])
                if manualExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        HandeField(placeholder: Strings.loginField, text: $value, mono: true, secure: true, onSubmit: connect)
                        Button(Strings.loginButton) { connect() }
                            .buttonStyle(HandeSecondaryButtonStyle())
                            .disabled(trimmedValue.isEmpty)
                        Text(Strings.loginManualHint)
                            .font(.system(size: 13))
                            .foregroundStyle(p.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private func connect() {
        let token = trimmedValue
        guard !token.isEmpty else { return }
        model.login(.accessCookie(token))
        value = ""
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
