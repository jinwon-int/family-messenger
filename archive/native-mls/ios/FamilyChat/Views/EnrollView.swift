// §5 E1 "새 기기" 화면: 자기 지문 + 등록 정보 공유. 키는 절대 표시하지 않는다(지문·공개키 hex 만, relay-app §1 과 동일).
// #574: 후보를 릴레이 우편함에 올린 상태(`AppModel.enrollment.mode == .sibling`)면 지문이 주인공 — 다른 기기의 승인 시트와 한 자리씩 비교한다
// (웹 `renderEnroll` 의 sibling 모드). 운영자 JSON 공유는 보조 경로로 남는다. `idTaken` 은 이 ID 를 다시 쓸 수 없다는 안내.
import SwiftUI
import FamilyMLSCore

struct EnrollView: View {
    @EnvironmentObject private var model: AppModel
    @State private var registrationJSON: String = ""

    var body: some View {
        NavigationStack {
            Form {
                switch model.enrollment.mode {
                case .sibling:
                    Section(header: Text(Strings.enrollSiblingTitle), footer: Text(siblingFooter)) {
                        Text(SelfService.fingerprintGroups(model.fingerprint))
                            .font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                            .accessibilityLabel(Strings.fingerprintLabel)
                            .accessibilityIdentifier("enroll-fingerprint")
                        LabeledContent(Strings.deviceIdLabel) { Text(model.deviceId).font(.footnote) }
                    }
                case .idTaken:
                    Section(header: Text(Strings.enrollIdTakenTitle), footer: Text(Strings.enrollIdTakenBody)) {
                        LabeledContent(Strings.deviceIdLabel) { Text(model.deviceId).font(.footnote) }
                    }
                case .operatorFlow:
                    Section(footer: Text(Strings.enrollOperatorBody)) {
                        LabeledContent(Strings.fingerprintLabel) {
                            Text(model.fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        }
                        LabeledContent(Strings.deviceIdLabel) { Text(model.deviceId).font(.footnote) }
                    }
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

    private var siblingFooter: String {
        guard let expires = model.enrollment.expiresAt else { return Strings.enrollSiblingBody }
        return Strings.enrollSiblingBody + "\n" + Strings.enrollSiblingExpires(expires)
    }
}
