// 한데 공유 확장(#643 1단계 + #669 2단계) — 공유 시트에서 「한데」를 고르면 뜨는 화면: 받은 내용 미리보기 + 보낼 대화방 고르기 + 「보내기」.
// 「보내기」는 먼저 **맡긴다**(App Group `share-outbox/`, Core `ShareHandoffStore.commit` — D-A3 크래시 안전) 그리고 직접 송신 조립이 있으면
// (`ShareEnvironment.direct`) 글·링크·소형 사진을 NSE 와 같은 `RoomSyncEngine` 으로 **바로 보낸다**(#664 D-A1·A4). 조각마다 처리 표시를
// 남기고(`markPiece`) 다 보냈으면 맡김을 지운다. 남은 조각(큰 파일·폴백)이 있으면 종전처럼 로컬 알림 「누르면 한데에서 보냅니다」 → 앱이 나머지만
// 보낸다(`AppModel.deliverPendingShares`, `claim` 이 표시된 조각을 뺀다). 직접 송신 조립이 없으면 1단계와 같다.
// 파일은 읽어 들일 때 메모리에 올리지 않는다(공유 확장 메모리 한도) — `loadFileRepresentation` 의 임시 파일을 확장 tmp 로 복사해 두었다가
// 맡길 때 복사하고, 직접 보낼 때만 한 조각씩(≤ `ShareDirectSend.maxDirectFileBytes`) 올린다.
import UIKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import Intents
import FamilyMLSCore

final class ShareViewController: UIViewController {
    /// `extensionContext` 는 viewDidLoad 때 있다 — 맨 윗줄 추천(#666)으로 열렸으면 그 방을 미리 고른다(지금 스코프의 식별자일 때만).
    private lazy var model: ShareModel = {
        let environment = ShareEnvironment.live()
        let conversation = (extensionContext?.intent as? INSendMessageIntent)?.conversationIdentifier
        let preferred = environment.flatMap { env in conversation.flatMap { ShareSuggestions.room(conversation: $0, scope: env.scope) } }
        return ShareModel(environment: environment, preferred: preferred)
    }()

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
    /// #669 직접 보내는 중(취소·다시 보내기 막음 — 중간에 닫으면 임대가 지난 뒤 앱이 이어받는다).
    @Published private(set) var sending = false
    /// #669 보냈다(또는 거절돼 화면에 사유를 남겼다) — 「보내기」를 다시 누를 수 없다(같은 내용이 두 번 가지 않게). 닫기만 남는다.
    @Published private(set) var finished = false
    /// 확장 전용 임시 디렉터리(맡기면 App Group 으로 복사하고 지운다).
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)

    /// `preferred` = 추천으로 열린 방(#666). 공유할 수 있는 방이면 그 방, 아니면(정지·사라짐) 첫 방.
    init(environment: ShareEnvironment?, preferred: RoomID? = nil) {
        self.environment = environment
        let targets = environment?.targets ?? []
        selected = preferred.flatMap { targets.contains($0) ? $0 : nil } ?? targets.first
    }

    var targets: [RoomID] { environment?.targets ?? [] }
    var canSend: Bool { !loading && !saving && !sending && !finished && problem == nil && selected != nil && (text != nil || !files.isEmpty) }
    /// 직접 송신이 가능한 상태인가(안내문 선택) — 실제로 보낼지는 조각마다 계획(D-A4)이 정한다.
    var sendsDirectly: Bool { environment?.direct != nil }

    /// 공유받은 항목을 글·링크·파일로 나눈다(등록된 타입 식별자로). UTType 에서는 `public.url`·`public.plain-text` 도 `public.data` 를
    /// 따르므로 순서가 중요하다: ① 동영상·사진(일반 식별자로 읽어 가장 알맞은 표현 — Live Photo 는 사진) → ② 웹 링크(지도 등 미리보기 데이터가
    /// 함께 와도 링크) → ③ 글·URL·패키지가 아닌 데이터(PDF·문서) → ④ 파일 URL(파일 앱, 폴더 제외) → ⑤ 글(서식 있는 글도 평문으로).
    /// 패키지(디렉터리 — iWork·Live Photo 묶음)는 파일 하나로 보낼 수 없어 받지 않는다.
    func load(_ items: [NSExtensionItem]) async {
        var texts: [String] = []
        var urls: [URL] = []
        var picked: [URL] = []
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
            let isMovie = types.contains(where: { $0.conforms(to: .movie) })
            let isImage = types.contains(where: { $0.conforms(to: .image) })
            let media: UTType? = isMovie ? .movie : (isImage ? .image : nil)
            let webURLType = types.first { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }
            let dataType = types.first { $0.conforms(to: .data) && !$0.conforms(to: .url) && !$0.conforms(to: .text)
                && !$0.conforms(to: .package) }
            let fileURLType = types.first { $0.conforms(to: .fileURL) }
            let textType = types.first { $0.conforms(to: .plainText) }
            if let media, let copy = await loadFile(provider, type: media) {
                picked.append(copy)
            } else if let webURLType, let url = await loadURL(provider, type: webURLType), !url.isFileURL {
                urls.append(url)
            } else if let dataType, let copy = await loadFile(provider, type: dataType) {
                picked.append(copy)
            } else if let fileURLType, let url = await loadURL(provider, type: fileURLType), url.isFileURL,
                      let copy = copyIntoScratch(url, name: url.lastPathComponent) {
                picked.append(copy)
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

    /// 맡기고(App Group) → 직접 송신 조립이 있으면 계획(D-A4)대로 바로 보내고 → 남은 조각이 있으면 로컬 알림. 맡기지 못하면 화면에 사유를
    /// 남기고 false. 영구 거절(D-A5)도 false — 사유를 보이고 시트를 열어 둔다(「닫기」). true 면 호출자가 시트를 닫는다.
    func commit() async -> Bool {
        guard canSend, let environment, let room = selected else { return false }
        saving = true
        let item: ShareHandoff.Item
        do {
            item = try environment.store.commit(scope: environment.scope, room: room, text: text, files: files)
            saving = false
        } catch let failure as ShareHandoff.Failure {
            saving = false
            problem = Strings.shareProblem(failure)
            return false
        } catch {
            saving = false
            problem = Strings.shareSaveFailed(error.localizedDescription)
            return false
        }
        // #669 맡김은 디스크에 있다 — 여기서 죽어도 앱이 보낸다(D-A3). 직접 보낼 수 있으면 조각 순서대로 보내고 표시한다.
        if let direct = environment.direct, let engine = try? direct.engine(room: room) {
            let store = environment.store
            let plan = ShareDirectSend.plan(item) { ShareHandoffStore.fileSize(store.fileURL(item, $0)) }
            if !plan.direct.isEmpty, store.beginSending(item.id) {
                sending = true
                let before = ShareFootprint.megabytes() ?? -1
                let report = await ShareDirectSend.run(plan: plan, item: item.id, store: store,
                                                       sender: ShareDirectSender(engine: engine, store: store, item: item))
                store.endSending(item.id)
                sending = false
                finished = true
                let after = ShareFootprint.megabytes() ?? -1
                // 실기기 측정(P2 → P3 D-A4 문턱): 조각 수·바이트·메모리. 내용·방 이름은 싣지 않는다.
                let bytes = plan.direct.reduce(0) { total, piece in
                    if case .file(let name) = piece { return total + (ShareHandoffStore.fileSize(store.fileURL(item, name)) ?? 0) }
                    return total
                }
                ShareDirectEnvironment.log.notice(
                    "direct-send pieces=\(plan.direct.count, privacy: .public) deferred=\(plan.deferred.count, privacy: .public) bytes=\(bytes, privacy: .public) sent=\(report.sent.count, privacy: .public) queued=\(report.queued.count, privacy: .public) refused=\(report.refused.count, privacy: .public) stopped=\(report.stopped ?? "-", privacy: .public) footprint_mb_before=\(before, privacy: .public) footprint_mb_after=\(after, privacy: .public)")
                if report.needsApp {
                    // 남은 조각(멈춤·미룸)은 앱이 — 표시된 조각은 `claim` 이 뺀다.
                    await notify(room: room, item: item, body: Strings.shareNotificationBody)
                } else {
                    store.finish(item.id)
                    if !report.queued.isEmpty { await notify(room: room, item: item, body: Strings.shareQueuedNotificationBody) }
                }
                if let refusal = report.refused.first {
                    problem = Strings.shareRefused(refusal.status)
                    return false
                }
                return true
            }
        }
        finished = true
        await notify(room: room, item: item, body: Strings.shareNotificationBody)
        return true
    }

    /// 로컬 알림. `room` = 푸시와 같은 키(탭하면 기존 규칙대로 그 방을 연다), 맡김 ID = 앱이 공유 알림임을 안다.
    /// 알림 권한이 없으면 뜨지 않는다 — 다음에 한데를 열 때 보낸다(화면 안내문). 잠금화면에도 보이므로 방 이름·내용은 싣지 않는다(#520).
    private func notify(room: RoomID, item: ShareHandoff.Item, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = Strings.shareNotificationTitle
        content.body = body
        content.userInfo = ["room": room, ShareHandoff.notificationKey: item.id]
        let request = UNNotificationRequest(identifier: "hande.share.\(item.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
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
                if (name as NSString).pathExtension.isEmpty {
                    // 일반 식별자(public.image 등)에는 정해진 확장자가 없다 — 실제 임시 파일의 확장자를 쓴다.
                    let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                    if !ext.isEmpty { name += ".\(ext)" }
                }
                continuation.resume(returning: Self.copy(url, into: scratch, name: name))
            }
        }
    }

    private func copyIntoScratch(_ url: URL, name: String) -> URL? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // 폴더는 파일 하나로 보낼 수 없다.
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return nil }
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
                Section {
                    Text(model.sendsDirectly ? Strings.shareHowItWorksDirect : Strings.shareHowItWorks).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(Strings.shareTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 보내는 중에는 닫지 않는다(닫아도 송신은 프로세스와 함께 끝나고, 임대가 지나면 앱이 이어받는다). 끝났으면 「닫기」.
                    Button(model.finished ? Strings.shareClose : Strings.shareCancel, action: cancel).disabled(model.sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.sending {
                        HStack(spacing: 6) { ProgressView(); Text(Strings.shareSending) }
                    } else {
                        Button(Strings.shareSend, action: send).disabled(!model.canSend)
                    }
                }
            }
        }
    }
}
