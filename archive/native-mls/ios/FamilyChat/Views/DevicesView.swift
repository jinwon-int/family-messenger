// 「내 기기」(#574 E5, 웹 `openDevicesSheet`): 체인의 내 subject 기기 전부(폐기 포함) + 등록 기기(registrar) 지정/해제, 승인 대기 새 기기.
// 새 기기 승인(#574 E2, 웹 `openApproveSheet` relay 모드): 후보 행 → 지문 비교 시트(지문은 **이 기기에서** `policy_fingerprint` 로 다시 계산해
// 릴레이 값과 같을 때만 보인다) → 「이 지문이 맞습니다」 → `sign_approval` → `POST /v2/devices/approvals`. 결정은 모두 `AppModel`/`SelfService`.
import SwiftUI
import FamilyMLSCore

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var busy: DeviceID?
    @State private var message: String?

    private var view: SelfService.RolesView { model.deviceRoles }

    var body: some View {
        List {
            if !model.candidates.isEmpty {
                Section(Strings.candidatesSectionTitle) {
                    ForEach(model.candidates, id: \.deviceId) { candidate in
                        CandidateRow(candidate: candidate)
                    }
                }
            }
            Section(footer: Text(Strings.devicesHint)) {
                if view.devices.isEmpty {
                    Text(model.me == nil ? Strings.devicesEmpty : Strings.devicesUnknownRelay).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(view.devices) { row in
                    DeviceRowView(row: row, busy: busy == row.deviceId) { grant in
                        Task { await setRoles(row.deviceId, grant: grant) }
                    }
                }
            }
            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(Strings.devicesTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setRoles(_ target: DeviceID, grant: Bool) async {
        busy = target
        message = Strings.rolesBusy
        defer { busy = nil }
        do {
            try await model.setRegistrar(target, grant: grant)
            message = Strings.rolesDone(target, grant: grant)
        } catch {
            message = Strings.selfServiceFailure(error)
        }
    }
}

/// 기기 한 행: ID · 사람 이름 · 지문(4자 묶음) · 상태/역할 표지 · 부여/해제 버튼(판정은 `SelfService.rolesActions`).
struct DeviceRowView: View {
    let row: SelfService.DeviceRow
    let busy: Bool
    let onRoles: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.deviceId).font(.headline)
                if row.isSelf { Pill(text: Strings.thisDevicePill, color: .secondary) }
                if row.registrar { Pill(text: Strings.registrarPill, color: Hande.ember) }
                if row.status != SelfService.statusActive { Pill(text: Strings.revokedPill, color: .red) }
            }
            Text(Strings.peopleNames[row.actor] ?? row.actor).font(.footnote).foregroundStyle(.secondary)
            if !row.fingerprint.isEmpty {
                Text(SelfService.fingerprintGroups(row.fingerprint)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            }
            if row.grant || row.release {
                Button(row.grant ? Strings.grantRegistrar : Strings.releaseRegistrar) { onRoles(row.grant) }
                    .buttonStyle(.bordered).disabled(busy)
            } else if row.lastRegistrar {
                Text(Strings.lastRegistrarHint).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 작은 표지(등록 기기 · 이 기기 · 폐기됨).
struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18)).foregroundStyle(color).clipShape(Capsule())
    }
}

/// 승인 대기 새 기기 한 행(🔔 알림·내 기기): 「지문 비교」 → 승인 시트, 「무시」.
struct CandidateRow: View {
    @EnvironmentObject private var model: AppModel
    let candidate: DeviceCandidate
    @State private var showApprove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.deviceId).font(.headline)
            Text(Strings.candidateBody(candidate.deviceId)).font(.footnote).foregroundStyle(.secondary)
            Text(Strings.candidateExpires(Date(timeIntervalSince1970: TimeInterval(candidate.expiresAt)))).font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button(Strings.candidateApproveButton) { showApprove = true }.buttonStyle(.borderedProminent)
                Button(Strings.candidateIgnoreButton) { model.dismissCandidate(candidate.deviceId) }.buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showApprove) { CandidateApprovalView(candidate: candidate).environmentObject(model) }
    }
}

/// 지문 비교 → 승인(웹 approve 시트 relay 모드). 지문은 이 기기에서 다시 계산한 값 — 릴레이 값과 다르면 승인 버튼 대신 불일치 안내.
struct CandidateApprovalView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let candidate: DeviceCandidate
    @State private var fingerprint: String?
    @State private var busy = false
    @State private var message: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(Strings.candidateConfirmHint)) {
                    LabeledContent(Strings.deviceIdLabel) { Text(candidate.deviceId).font(.footnote) }
                    if let fingerprint {
                        Text(SelfService.fingerprintGroups(fingerprint))
                            .font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                            .accessibilityLabel(Strings.candidateFingerprintLabel)
                            .accessibilityIdentifier("approve-fingerprint")
                    }
                }
                Section {
                    if done {
                        Text(Strings.candidateDone(candidate.deviceId)).font(.footnote)
                        Button(Strings.close) { dismiss() }
                    } else if fingerprint != nil {
                        Button(Strings.candidateConfirmButton) { Task { await approve() } }.disabled(busy)
                        if busy { Text(Strings.candidateApproving).font(.footnote).foregroundStyle(.secondary) }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(Strings.candidatesSectionTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(Strings.close) { dismiss() } } }
            .onAppear(perform: compare)
        }
    }

    private func compare() {
        do { fingerprint = try model.candidateFingerprint(candidate.deviceId) }
        catch { message = Strings.selfServiceFailure(error) }
    }

    private func approve() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await model.approveCandidate(candidate.deviceId)
            done = true
        } catch {
            message = Strings.selfServiceFailure(error)
        }
    }
}
