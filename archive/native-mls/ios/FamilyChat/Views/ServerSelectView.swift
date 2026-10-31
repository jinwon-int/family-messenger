// 첫 화면(#584 PR 2, Matrix 홈서버 방식): 서버 주소 입력 → 탐색(`.well-known/hande` → `/v2/health`) → 이름·주소 확인 →
// 「이 서버로 계속」 → 기존 로그인 흐름(LoginView). 판정은 Core `ServerDiscoverer`(순수), 상태는 AppModel(`serverCandidate`·`discovering`·
// `lastError`) — 이 화면은 얇다. 빌드 기본값(`FC_RELAY_URL`)이 있으면 미리 채운다.
// 디자인 2차-A(§A2 ①): 진행 막대 1/4 + 워드마크 30 + 제목 + 「회원가입이 없습니다」 선언 카드(불 8%·선 35%) + 모노 입력 칸 + 1줄 안내·「자세히」 →
// 찾으면 자리 점 + 이름 + 모노 주소 + 「찾았어요」 카드, 아래 버튼이 「서버 찾기」→「이 서버로 계속」. 오류는 카드 자리에 warn 선 + 1줄.
// QR 스캔: 이 프로젝트에는 카메라 권한(NSCameraUsageDescription)이 없어 넣지 않았다 — 웹 설정 화면의 `hande://server?url=…` 링크를
// 붙여넣거나 열면(onOpenURL, CFBundleURLTypes `hande`) 같은 경로로 탐색한다. TODO(#584 후속): 카메라 권한과 함께 DataScannerViewController.
import SwiftUI
import FamilyMLSCore

struct ServerSelectView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hande) private var p
    @State private var input = ""

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        OnboardingScreen(step: 1, title: Strings.serverStepTitle, wordmark: true) {
            // #584 PR 4(가이드라인 4.2 대비): 서버 주소가 없어도 앱이 무엇인지 알 수 있는 선언 — 첫 화면 맨 위 카드.
            HandeCard(fill: p.ember.opacity(0.08), stroke: p.ember.opacity(0.35)) {
                Text(Strings.serverDeclaration)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(p.ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("server-intro")

            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(Strings.serverAddressLabel)
                HandeField(placeholder: Strings.serverAddressPlaceholder, text: $input, mono: true,
                           invalid: model.lastError != nil, keyboard: .URL, contentType: .URL, onSubmit: find)
                    .accessibilityLabel(Strings.serverField)
                    .accessibilityIdentifier("server-input")
                DetailDisclosure(hint: Strings.serverAddressHint, text: Strings.serverAddressDetail)
                // 안내서·개인정보처리방침 링크(Safari) — 심사관도 서버 없이 앱이 무엇인지 알 수 있게.
                HStack(spacing: 16) {
                    Link(Strings.serverHelp, destination: PolicyLinks.site)
                    Link(Strings.privacyPolicy, destination: PolicyLinks.privacy)
                }
                .font(.system(size: 13, weight: .medium))
                .tint(p.ember)
                .padding(.horizontal, 4)
            }

            if let error = model.lastError {
                HandeCard(stroke: p.warn, lineWidth: 1.5) {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(p.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let found = model.serverCandidate {
                HandeCard {
                    HStack(spacing: 12) {
                        SeatDots(people: 2, agents: 1, size: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(found.name ?? Strings.serverNoName)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(p.ink)
                            Text(found.baseURL.host ?? found.baseURL.absoluteString)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(p.inkDim)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(Strings.serverFound)
                            .font(.system(size: 13))
                            .foregroundStyle(p.inkDim)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } footer: {
            if let found = model.serverCandidate, model.lastError == nil {
                Button(Strings.serverContinue) { Task { await model.selectServer(found) } }
                    .buttonStyle(HandePrimaryButtonStyle())
                    .disabled(model.discovering)
                    .accessibilityIdentifier("server-continue")
            } else {
                Button {
                    find()
                } label: {
                    HStack(spacing: 8) {
                        if model.discovering { ProgressView().tint(p.onEmber) }
                        Text(model.discovering ? Strings.serverSearching : Strings.serverFind)
                    }
                }
                .buttonStyle(HandePrimaryButtonStyle())
                .disabled(model.discovering || trimmed.isEmpty)
                .accessibilityIdentifier("server-find")
            }
        }
        .onAppear {
            if input.isEmpty, let prefill = model.defaultRelayURL { input = prefill.absoluteString }
        }
        .onOpenURL { url in
            guard let link = ServerDiscovery.serverLink(url.absoluteString) else { return }
            input = link
            find()
        }
    }

    private func find() {
        let raw = input
        Task { await model.discoverServer(raw) }
    }
}

/// 로그인·이름 선택 화면 아래 한 줄: 「지금 서버 · 이름」(보조색) + 「다른 서버 선택」(불 색 링크, #584) — 빌드 기본 서버가 자동으로 잡힌 설치가
/// 다른 서버로 가는 길. 「서버 바꾸기」(설정)와 같은 `AppModel.changeServer`.
struct ServerSwitchSection: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hande) private var p

    var body: some View {
        if let server = model.server {
            HStack(spacing: 10) {
                Text(Strings.serverCurrentLine(server.displayName))
                    .font(.system(size: 13))
                    .foregroundStyle(p.inkDim)
                    .lineLimit(1)
                Button(Strings.serverOther) { Task { await model.changeServer() } }
                    .buttonStyle(HandeLinkButtonStyle(size: 13))
                    .accessibilityIdentifier("server-other")
            }
            .padding(.horizontal, 4)
        }
    }
}
