// 첫 실행: 이 기기 사용자 이름(actor) 선택(#271 §5, 가족 투입). 기기 ID `<actor>-iphone-<hex>` 가 이 이름으로 만들어지고
// 정책 체인·relay-app·알림 제목이 모두 이 actor 를 쓴다. 기존 설치(ID 가 이미 있음)는 이 화면을 보지 않는다.
// 디자인 2차-A(§A2 ②): 진행 막대 2/4 + 제목 + 라벨 + 모노 입력 칸 + 「한 번 정하면 바꿀 수 없어요. 자세히」(형식 규칙·이유는 접힘).
// 형식이 틀리면 칸 선이 warn 으로 바뀌고 밑에 1줄(모델 값 `Strings.actorInvalid` 는 그대로, 화면 문구만 새것). 뒤로 가는 길은 모델에
// 「다른 서버 선택」(changeServer)뿐이라 뒤로 버튼 대신 아래 `ServerSwitchSection` 을 둔다.
import SwiftUI
import FamilyMLSCore

struct ActorSetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hande) private var p
    @State private var name = ""
    @State private var busy = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var invalid: Bool { model.lastError != nil }

    var body: some View {
        OnboardingScreen(step: 2, title: Strings.actorStepTitle) {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(Strings.actorStepLabel)
                HandeField(placeholder: Strings.actorStepPlaceholder, text: $name, mono: true, invalid: invalid, onSubmit: submit)
                    .accessibilityLabel(Strings.actorField)
                if invalid {
                    Text(Strings.actorStepInvalid)
                        .font(.system(size: 14))
                        .foregroundStyle(p.warn)
                        .padding(.horizontal, 4)
                }
                DetailDisclosure(hint: Strings.actorStepHint, text: Strings.actorStepDetail)
            }
            // #584: 현재 서버 + 「다른 서버 선택」
            ServerSwitchSection()
                .padding(.top, 6)
        } footer: {
            Button(Strings.actorButton) { submit() }
                .buttonStyle(HandePrimaryButtonStyle())
                .disabled(busy || trimmed.isEmpty)
        }
    }

    private func submit() {
        guard !busy, !trimmed.isEmpty else { return }
        busy = true
        Task {
            await model.chooseActor(name)
            busy = false
        }
    }
}
