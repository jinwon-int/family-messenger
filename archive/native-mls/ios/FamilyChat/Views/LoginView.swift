// §6 인증 — 뼈대: 세션 값(CF_Authorization JWT 또는 Bearer)을 붙여넣는 임시 화면. WKWebView 로그인(A)은 §12-C/D 에서.
import SwiftUI
import FamilyMLSCore

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(Strings.loginHint)) {
                    SecureField(Strings.loginField, text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button(Strings.loginButton) {
                    model.login(.accessCookie(value))
                    value = ""
                }
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle(Strings.loginTitle)
        }
    }
}
