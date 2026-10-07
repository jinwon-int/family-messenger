// §5 E1 "새 기기" 화면: 자기 지문 + 등록 정보 공유. 키는 절대 표시하지 않는다(지문·공개키 hex 만, relay-app §1 과 동일).
import SwiftUI
import FamilyMLSCore

struct EnrollView: View {
    @EnvironmentObject private var model: AppModel
    @State private var registrationJSON: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(Strings.enrollBody)) {
                    LabeledContent(Strings.fingerprintLabel) {
                        Text(model.fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                    LabeledContent(Strings.deviceIdLabel) { Text(model.deviceId).font(.footnote) }
                }
                Section {
                    if !registrationJSON.isEmpty {
                        ShareLink(item: registrationJSON) { Label(Strings.shareRegistration, systemImage: "square.and.arrow.up") }
                    }
                    Text(Strings.waitingOperator).font(.footnote).foregroundStyle(.secondary)
                    Button(Strings.enrolledButton) { Task { await model.refresh() } }
                }
            }
            .navigationTitle(Strings.enrollTitle)
            .onAppear { registrationJSON = model.registrationJSON() }
        }
    }
}
