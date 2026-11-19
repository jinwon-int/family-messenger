// §12-E 초대: 상대 기기의 키 패키지를 소비해 Add commit + Welcome 을 올린다(`AppModel.invite`, relay-app `초대`와 같은 순서).
// 상대가 먼저 이 방에 '참여 요청'(키 패키지 게시)을 해 두어야 한다 — 없으면 원인과 다음 행동을 안내한다.
import SwiftUI
import FamilyMLSCore

/// 기기 ID 규칙(릴레이 `validIdentifier`): 영문·숫자·`-`·`_`, 1~64자.
enum DeviceName {
    static func isValid(_ id: String) -> Bool {
        guard (1...64).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }
}

/// 초대 창 「이 자리에 있는 사람」 한 줄(오너 2026-11-19): 사람은 기기 ID 앞부분(actor)으로 묶고, 불지기(에이전트)는 기기마다
/// 따로 — 에이전트 기기는 모두 `bot-<노드>` 라 actor 로 묶으면 공명·서서가 한 줄로 합쳐진다.
struct RoomPerson: Equatable, Identifiable {
    let id: String
    let name: String
    let devices: [DeviceID]
    let isMe: Bool
    let isAgent: Bool
}

enum RoomMemberList {
    /// 명단(기기 ID) → 사람 줄. 순서: 나 → 가족(이름순) → 불지기(이름순). 같은 사람의 기기는 명단 순서 그대로.
    static func people(roster: [DeviceID], myDevice: DeviceID, agentActors: Set<String>,
                       name: (DeviceID) -> String) -> [RoomPerson] {
        let myActor = MessageRecord.actor(of: myDevice)
        var order: [String] = []
        var devices: [String: [DeviceID]] = [:]
        var agent: [String: Bool] = [:]
        for device in roster {
            let actor = MessageRecord.actor(of: device)
            let isAgent = agentActors.contains(actor)
            let key = isAgent ? device : actor
            if devices[key] == nil { order.append(key); agent[key] = isAgent }
            if !(devices[key]?.contains(device) ?? false) { devices[key, default: []].append(device) }
        }
        let rows = order.map { key -> RoomPerson in
            let list = devices[key] ?? []
            let isAgent = agent[key] ?? false
            return RoomPerson(id: key, name: name(list.first ?? key), devices: list,
                              isMe: !isAgent && !myDevice.isEmpty && key == myActor, isAgent: isAgent)
        }
        func rank(_ p: RoomPerson) -> Int { p.isMe ? 0 : (p.isAgent ? 2 : 1) }
        return rows.sorted { a, b in rank(a) != rank(b) ? rank(a) < rank(b) : a.name < b.name }
    }
}

struct InviteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let room: RoomID
    @State private var target = ""
    @State private var busy = false
    @State private var message: String?
    /// 이 방 사람들(nil = 명단을 아직 읽지 못함). 창이 뜰 때·초대한 뒤 다시 읽는다.
    @State private var people: [RoomPerson]?

    private var trimmed: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                // 오너 2026-11-19: 누르면 먼저 이 방에 누가 있는지, 그 아래 초대.
                Section(header: Text(Strings.membersSection(people?.count ?? 0))) {
                    if let people, !people.isEmpty {
                        ForEach(people) { memberRow($0) }
                    } else {
                        Text(Strings.membersUnavailable).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("invite-members")
                Section(header: Text(Strings.membersInviteSection), footer: Text(Strings.inviteHint)) {
                    TextField(Strings.inviteField, text: $target)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Button(Strings.inviteButton) { Task { await invite() } }
                        .disabled(busy || trimmed.isEmpty || !model.canRequestJoin)
                    if busy { ProgressView() }
                }
            }
            .navigationTitle(Strings.inviteTitle)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(Strings.close) { dismiss() } } }
            .onAppear(perform: loadPeople)
        }
    }

    private func loadPeople() {
        guard let roster = model.roomRoster(room) else { people = nil; return }
        people = RoomMemberList.people(roster: roster, myDevice: model.deviceId, agentActors: model.agentRoster.actors,
                                       name: AgentRosterNames.person)
    }

    /// 이름 + (나 / 불지기) + 기기 종류(아이폰 · 아이패드 …, 모르면 「기기 N대」).
    private func memberRow(_ person: RoomPerson) -> some View {
        let kinds = person.devices.compactMap(DeviceKindName.of)
        let detail = person.isAgent ? nil
            : (kinds.count == person.devices.count && !kinds.isEmpty ? kinds.joined(separator: " · ") : Strings.memberDeviceCount(person.devices.count))
        return HStack(spacing: 8) {
            Image(systemName: person.isAgent ? "flame" : "person.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(person.name)
            if person.isMe { tag(Strings.memberMe) }
            if person.isAgent { tag(Strings.memberAgent) }
            Spacer(minLength: 8)
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
    }

    private func invite() async {
        guard DeviceName.isValid(trimmed) else { message = Strings.deviceIdInvalid; return }
        guard trimmed != model.deviceId else { message = Strings.inviteSelf; return }
        busy = true
        defer { busy = false }
        do {
            try await model.invite(room: room, target: trimmed)
            message = Strings.inviteDone(trimmed)
            await model.refresh()
            loadPeople()
        } catch {
            message = Strings.membershipFailure(error)
        }
    }
}
