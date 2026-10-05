// 스파이크 A 셸: 앱은 "이 기기의 지문"만 보여준다. 영속·릴레이·키체인은 #271 §12-B/C 범위.
import SwiftUI

@main
struct FamilyMLSSpikeApp: App {
    var body: some Scene {
        WindowGroup { FingerprintView() }
    }
}

struct FingerprintView: View {
    @State private var fingerprint = "…"
    @State private var error = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("패밀리챗 MLS 스파이크").font(.headline)
            Text("이 기기의 지문(메모리 전용, 재시작마다 새 기기)").font(.footnote)
            Text(fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .padding()
        .task {
            do {
                let device = try MlsDevice(identity: "owner-iphone")
                fingerprint = try device.fingerprint()
            } catch {
                self.error = "\(error)"
            }
        }
    }
}
