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
                    Button(Strings.enrolledButton) { model.markEnrolled() }
                }
            }
            .navigationTitle(Strings.enrollTitle)
            .task { registrationJSON = model.registrationJSON() }
        }
    }
}

extension AppModel {
    /// 등록 JSON(운영자 CLI 입력). subject 는 로그인 자격증명에서 — 뼈대에서는 자리표시자.
    func registrationJSON() -> String {
        guard let key = try? engineForUI()?.publicKey() else { return "" }
        let reg = DeviceIdentity.Registration(
            deviceId: deviceId,
            actor: String(deviceId.split(separator: "-", maxSplits: 1).first ?? ""),
            subject: "<cf-access-subject>",
            signingKey: DeviceIdentity.hex(key),
            fingerprint: fingerprint)
        return reg.json()
    }
}
