// 첫 화면(#584 PR 2, Matrix 홈서버 방식): 서버 주소 입력 → 탐색(`.well-known/hande` → `/v2/health`) → 이름·주소 확인 →
// 「이 서버로 계속」 → 기존 로그인 흐름(LoginView). 판정은 Core `ServerDiscoverer`(순수), 상태는 AppModel(`serverCandidate`·`discovering`·
// `lastError`) — 이 화면은 얇다. 빌드 기본값(`FC_RELAY_URL`)이 있으면 미리 채운다.
// QR 스캔: 이 프로젝트에는 카메라 권한(NSCameraUsageDescription)이 없어 넣지 않았다 — 웹 설정 화면의 `hande://server?url=…` 링크를
// 붙여넣거나 열면(onOpenURL, CFBundleURLTypes `hande`) 같은 경로로 탐색한다. TODO(#584 후속): 카메라 권한과 함께 DataScannerViewController.
import SwiftUI
import FamilyMLSCore

struct ServerSelectView: View {
    @EnvironmentObject private var model: AppModel
    @State private var input = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(Strings.serverHint)) {
                    TextField(Strings.serverField, text: $input)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { find() }
                        .accessibilityIdentifier("server-input")
                    Button {
                        find()
                    } label: {
                        HStack {
                            Label(model.discovering ? Strings.serverSearching : Strings.serverFind, systemImage: "magnifyingglass")
                            if model.discovering { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(model.discovering || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("server-find")
                    if let error = model.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                if let found = model.serverCandidate {
                    Section(header: Text(Strings.serverFoundTitle)) {
                        LabeledContent(Strings.serverNameLabel) { Text(found.name ?? Strings.serverNoName) }
                        LabeledContent(Strings.serverURLLabel) {
                            Text(found.baseURL.absoluteString).font(.footnote).textSelection(.enabled)
                        }
                        Text(Strings.serverVia(found.discoveredVia)).font(.footnote).foregroundStyle(.secondary)
                        Button(Strings.serverContinue) { Task { await model.selectServer(found) } }
                            .disabled(model.discovering)
                            .accessibilityIdentifier("server-continue")
                    }
                }
            }
            .navigationTitle(Strings.serverTitle)
            .onAppear {
                if input.isEmpty, let prefill = model.defaultRelayURL { input = prefill.absoluteString }
            }
            .onOpenURL { url in
                guard let link = ServerDiscovery.serverLink(url.absoluteString) else { return }
                input = link
                find()
            }
        }
    }

    private func find() {
        let raw = input
        Task { await model.discoverServer(raw) }
    }
}

/// 로그인·이름 선택 화면 아래 칸: 현재 서버 + 「다른 서버 선택」(#584) — 빌드 기본 서버가 자동으로 잡힌 설치가 다른 서버로 가는 길.
/// 「서버 바꾸기」(설정)와 같은 `AppModel.changeServer`.
struct ServerSwitchSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let server = model.server {
            Section {
                LabeledContent(Strings.serverSection) { Text(server.displayName).font(.footnote) }
                Button(Strings.serverOther) { Task { await model.changeServer() } }
                    .accessibilityIdentifier("server-other")
            }
        }
    }
}
