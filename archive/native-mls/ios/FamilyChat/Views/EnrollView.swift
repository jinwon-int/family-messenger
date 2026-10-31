// §5 E1 "새 기기" 화면: 자기 지문 + 등록 정보 공유. 키는 절대 표시하지 않는다(지문·공개키 hex 만, relay-app §1 과 동일).
// #574: 후보를 릴레이 우편함에 올린 상태(`AppModel.enrollment.mode == .sibling`)면 지문이 주인공 — 다른 기기의 승인 시트와 한 자리씩 비교한다
// (웹 `renderEnroll` 의 sibling 모드). 운영자 JSON 공유는 보조 경로로 남는다. `idTaken` 은 이 ID 를 다시 쓸 수 없다는 안내.
// 디자인 2차-A(§A2 ④ 상태 2): 진행 막대 4/4 + 제목 + 1줄 + 「자세히」(모드별 긴 안내) + 지문 1열 8행(승인 시트와 같은 행·번호) + 기기 ID 모노 +
// 「운영자 승인을 기다리는 중」(점 3개 고정 — 움직이면 일하는 중을 암시, #601) + 「등록 정보 공유」(보조) + 「등록 확인」 링크.
// 옛 대기 문구의 기술값 「(403 device_subject_mismatch)」는 화면에서 뺐다(`Strings.enrollDiagnosticToken` — 진단 기록 몫).
import SwiftUI
import FamilyMLSCore

struct EnrollView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hande) private var p
    @State private var registrationJSON: String = ""

    var body: some View {
        OnboardingScreen(step: 4, title: Strings.enrollTitle) {
            DetailDisclosure(hint: Strings.enrollStepLine, hintSize: 15, text: detailText)

            if model.enrollment.mode == .idTaken {
                HandeCard(stroke: p.warn, lineWidth: 1.5) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Strings.enrollIdTakenTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(p.ink)
                        Text(Strings.enrollIdTakenBody)
                            .font(.system(size: 14))
                            .foregroundStyle(p.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                deviceIdCaption
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(Strings.fingerprintLabel)
                    FingerprintList(groups: FingerprintRows.make(model.fingerprint))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Strings.fingerprintLabel)
                        .accessibilityIdentifier("enroll-fingerprint")
                    deviceIdCaption
                }
                HStack(spacing: 10) {
                    DotsRow(color: p.person)
                    Text(statusLine)
                        .font(.system(size: 15))
                        .foregroundStyle(p.ink)
                }
                .padding(.horizontal, 4)
            }
        } footer: {
            VStack(spacing: 10) {
                if !registrationJSON.isEmpty {
                    ShareLink(item: registrationJSON) { Text(Strings.shareRegistration) }
                        .buttonStyle(HandeSecondaryButtonStyle())
                }
                Button(Strings.enrolledButton) { Task { await model.refresh() } }
                    .buttonStyle(HandeLinkButtonStyle())
                    .frame(minHeight: 44)
            }
        }
        .onAppear { registrationJSON = model.registrationJSON() }
    }

    private var deviceIdCaption: some View {
        Text("\(Strings.deviceIdLabel) \(model.deviceId)")
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(p.inkDim)
            .textSelection(.enabled)
            .padding(.horizontal, 4)
    }

    /// 「자세히」 안의 긴 안내 — 모드별 기존 문구.
    private var detailText: String {
        switch model.enrollment.mode {
        case .sibling: return Strings.enrollSiblingBody
        case .idTaken: return Strings.enrollIdTakenBody
        case .operatorFlow: return Strings.enrollOperatorBody
        }
    }

    /// 대기 문구: 형제 기기 모드는 「다른 기기의 승인을 기다리는 중 · HH:mm까지」(만료 시각만, 카운트다운 없음).
    private var statusLine: String {
        switch model.enrollment.mode {
        case .sibling:
            guard let expires = model.enrollment.expiresAt else { return Strings.enrollWaitingSibling }
            return Strings.enrollWaitingSiblingUntil(expires)
        case .idTaken, .operatorFlow:
            return Strings.enrollWaitingOperator
        }
    }
}
