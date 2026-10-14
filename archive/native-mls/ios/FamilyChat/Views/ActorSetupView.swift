// 첫 실행: 이 기기 사용자 이름(actor) 선택(#271 §5, 가족 투입). 기기 ID `<actor>-iphone-<hex>` 가 이 이름으로 만들어지고
// 정책 체인·relay-app·알림 제목이 모두 이 actor 를 쓴다. 기존 설치(ID 가 이미 있음)는 이 화면을 보지 않는다.
import SwiftUI
import FamilyMLSCore

struct ActorSetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(Strings.actorHint)) {
                    TextField(Strings.actorField, text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { submit() }
                }
                if let error = model.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Button(Strings.actorButton) { submit() }
                    .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle(Strings.actorTitle)
        }
    }

    private func submit() {
        busy = true
        Task {
            await model.chooseActor(name)
            busy = false
        }
    }
}
