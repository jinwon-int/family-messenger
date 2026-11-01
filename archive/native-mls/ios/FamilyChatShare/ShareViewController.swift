// 한데 공유 확장(#643 1단계) — 공유 시트에서 「한데」를 고르면 뜨는 화면: 받은 내용 미리보기 + 보낼 대화방 고르기 + 「보내기」.
// 「보내기」는 보내지 않고 **맡긴다**(결정 D1): App Group `share-outbox/` 에 쓰고(Core `ShareHandoffStore.commit`) 로컬 알림
// 「누르면 한데에서 보냅니다」를 띄운 뒤 닫는다. 실제 송신은 앱이 같은 모델·같은 경로로 한다(`AppModel.deliverPendingShares`).
// 파일은 메모리에 올리지 않는다(공유 확장 메모리 한도) — `loadFileRepresentation` 의 임시 파일을 확장 tmp 로 복사해 두었다가 맡길 때 복사한다.
import UIKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import FamilyMLSCore

final class ShareViewController: UIViewController {
    private let model = ShareModel(environment: ShareEnvironment.live())

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareView(model: model, cancel: { [weak self] in self?.finish(cancelled: true) },
                             send: { [weak self] in self?.send() })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { await model.load(items) }
    }

    private func send() {
        Task {
            guard await model.commit() else { return }
            finish(cancelled: false)
        }
    }

    private func finish(cancelled: Bool) {
        model.cleanup()
        if cancelled {
            extensionContext?.cancelRequest(withError: NSError(domain: "com.seoyoon-family.hande.share", code: NSUserCancelledError))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    let environment: ShareEnvironment?
    @Published private(set) var loading = true
    @Published private(set) var text: String?
    @Published private(set) var files: [URL] = []
    @Published var selected: RoomID?
    @Published private(set) var problem: String?
    @Published private(set) var saving = false
    /// 확장 전용 임시 디렉터리(맡기면 App Group 으로 복사하고 지운다).
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)

    init(environment: ShareEnvironment?) {
        self.environment = environment
        selected = environment?.targets.first
    }

    var targets: [RoomID] { environment?.targets ?? [] }
    var canSend: Bool { !loading && !saving && problem == nil && selected != nil && (text != nil || !files.isEmpty) }

    /// 공유받은 항목을 글·링크·파일로 나눈다(등록된 타입 식별자로). UTType 에서는 `public.url`·`public.plain-text` 도 `public.data` 를
    /// 따르므로 순서가 중요하다: ① 글·URL 이 아닌 데이터(사진·동영상·PDF·문서) = 파일 → ② URL(웹 링크, 파일 URL 이면 복사해 파일)
    /// → ③ 글(서식 있는 글도 평문으로).
    func load(_ items: [NSExtensionItem]) async {
        var texts: [String] = []
        var urls: [URL] = []
        var picked: [URL] = []
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
            let fileType = types.first { ($0.conforms(to: .data) || $0.conforms(to: .package))
                && !$0.conforms(to: .url) && !$0.conforms(to: .text) }
            let urlType = types.first { $0.conforms(to: .url) }
            let textType = types.first { $0.conforms(to: .plainText) }
            if let fileType, let copy = await loadFile(provider, type: fileType) {
                picked.append(copy)
            } else if let urlType, let url = await loadURL(provider, type: urlType) {
                if url.isFileURL {
                    if let copy = copyIntoScratch(url, name: url.lastPathComponent) { picked.append(copy) }
                } else {
                    urls.append(url)
                }
            } else if let textType, let value = await loadText(provider, type: textType) {
                texts.append(value)
            }
        }
        text = ShareHandoff.composeText(texts, urls: urls)
        files = picked
        loading = false
        validate()
    }

    private func validate() {
        do {
            try ShareHandoffStore.validate(text: text, files: files, maxFileBytes: ShareHandoff.maxFileBytes())
            problem = nil
        } catch let failure as ShareHandoff.Failure {
            problem = Strings.shareProblem(failure)
        } catch {
            problem = Strings.shareSaveFailed("\(error)")
        }
    }

    /// 맡기고(App Group) 로컬 알림을 띄운다. 실패하면 화면에 사유를 남기고 false.
    func commit() async -> Bool {
        guard canSend, let environment, let room = selected else { return false }
        saving = true
        defer { saving = false }
        let item: ShareHandoff.Item
        do {
            item = try environment.store.commit(scope: environment.scope, room: room, text: text, files: files)
        } catch let failure as ShareHandoff.Failure {
            problem = Strings.shareProblem(failure)
            return false
        } catch {
            problem = Strings.shareSaveFailed(error.localizedDescription)
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = Strings.shareNotificationTitle
        content.body = Strings.shareNotificationBody
        // `room` = 푸시와 같은 키(탭하면 기존 규칙대로 그 방을 연다), 맡김 ID = 앱이 공유 알림임을 안다.
        content.userInfo = ["room": room, ShareHandoff.notificationKey: item.id]
        let request = UNNotificationRequest(identifier: "hande.share.\(item.id)", content: content, trigger: nil)
        // 알림 권한이 없으면 뜨지 않는다 — 다음에 한데를 열 때 보낸다(화면 안내문).
        try? await UNUserNotificationCenter.current().add(request)
        return true
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - NSItemProvider 읽기

    private func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, _ in
                switch value {
                case let url as URL: continuation.resume(returning: url)
                case let data as Data: continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                case let string as String: continuation.resume(returning: URL(string: string))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(_ provider: NSItemProvider, type: UTType) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, _ in
                switch value {
                case let string as String: continuation.resume(returning: string)
                case let data as Data: continuation.resume(returning: String(data: data, encoding: .utf8))
                case let attributed as NSAttributedString: continuation.resume(returning: attributed.string)
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 임시 파일은 콜백 안에서만 유효하다 — 그 안에서 확장 tmp 로 복사한다(메모리에 올리지 않음).
    private func loadFile(_ provider: NSItemProvider, type: UTType) async -> URL? {
        let suggested = provider.suggestedName
        let scratch = self.scratch
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                var name = suggested ?? url.lastPathComponent
                if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += ".\(ext)" }
                continuation.resume(returning: Self.copy(url, into: scratch, name: name))
            }
        }
    }

    private func copyIntoScratch(_ url: URL, name: String) -> URL? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return Self.copy(url, into: scratch, name: name)
    }

    nonisolated private static func copy(_ url: URL, into directory: URL, name: String) -> URL? {
        let slot = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = slot.appendingPathComponent(name.isEmpty ? "file" : name)
        do {
            try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    let cancel: () -> Void
    let send: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.loading {
                        HStack(spacing: 8) { ProgressView(); Text(Strings.shareLoading) }
                    } else {
                        if let text = model.text {
                            Text(text.count > 300 ? String(text.prefix(300)) + "…" : text).lineLimit(6)
                        }
                        if !model.files.isEmpty {
                            Label(Strings.shareFiles(model.files.count), systemImage: "paperclip")
                        }
                    }
                }
                if model.targets.isEmpty {
                    Section { Text(Strings.shareNoRooms).foregroundStyle(.secondary) }
                } else {
                    Section(Strings.sharePickRoom) {
                        ForEach(model.targets, id: \.self) { room in
                            Button { model.selected = room } label: {
                                HStack {
                                    Text(Strings.roomLabel(room)).foregroundStyle(.primary)
                                    Spacer()
                                    if model.selected == room { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                        }
                    }
                }
                if let problem = model.problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
                Section { Text(Strings.shareHowItWorks).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle(Strings.shareTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Strings.shareCancel, action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.shareSend, action: send).disabled(!model.canSend)
                }
            }
        }
    }
}
