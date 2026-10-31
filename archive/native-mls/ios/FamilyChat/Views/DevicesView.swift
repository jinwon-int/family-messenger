// 「내 기기」(#574 E5, 웹 `openDevicesSheet`): 체인의 내 subject 기기 전부(폐기 포함) + 등록 기기(registrar) 지정/해제, 승인 대기 새 기기.
// 새 기기 승인(#574 E2, 웹 `openApproveSheet` relay 모드): 후보 카드 → 지문 비교 시트(지문은 **이 기기에서** `policy_fingerprint` 로 다시 계산해
// 릴레이 값과 같을 때만 보인다) → 8행을 하나씩 눌러 맞춘 뒤 「승인」 → `sign_approval` → `POST /v2/devices/approvals`. 결정은 모두 `AppModel`/`SelfService`.
// 디자인 2차-A(§A1): 「대충 승인」을 막는 세 겹 — 등록 화면과 같은 1열·같은 번호, 행마다 직접 표시(전부 표시 전엔 「승인」 꺼짐),
// 「지문이 다르면…」 경고 상자 + 같은 높이의 「다릅니다」. 결과는 글자로만(체크 배지 없음), 만료는 시각으로만(카운트다운 없음).
// 폐기(revoke)는 iOS 에 API 가 없어 이 화면에도 없다.
import SwiftUI
import FamilyMLSCore
#if canImport(UIKit)
import UIKit
#endif

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.hande) private var p
    @State private var busy: DeviceID?
    @State private var message: String?

    private var view: SelfService.RolesView { model.deviceRoles }

    var body: some View {
        List {
            if !model.candidates.isEmpty {
                Section {
                    ForEach(model.candidates, id: \.deviceId) { candidate in
                        CandidateRow(candidate: candidate)
                            .listRowStyling()
                    }
                } header: {
                    SectionLabel(Strings.candidatesSectionTitle)
                }
            }
            Section {
                if view.devices.isEmpty {
                    HandeCard {
                        Text(model.me == nil ? Strings.devicesEmpty : Strings.devicesUnknownRelay)
                            .font(.system(size: 14))
                            .foregroundStyle(p.inkDim)
                    }
                    .listRowStyling()
                }
                ForEach(view.devices) { row in
                    DeviceRowView(row: row, busy: busy == row.deviceId) { grant in
                        Task { await setRoles(row.deviceId, grant: grant) }
                    }
                    .listRowStyling()
                }
            } header: {
                SectionLabel(Strings.devicesTitle)
            } footer: {
                Text(Strings.devicesHint)
                    .font(.system(size: 13))
                    .foregroundStyle(p.inkDim)
                    .padding(.horizontal, 4)
            }
            if let message {
                Section {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(p.inkDim)
                        .listRowStyling()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CampfireBackground())
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

/// 목록 칸 제목 13/600 보조색(시스템 대문자 변환 없음).
struct SectionLabel: View {
    let text: String
    @Environment(\.hande) private var p
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(p.inkDim)
            .textCase(nil)
            .padding(.horizontal, 4)
    }
}

private extension View {
    /// 투명 행 배경 + 구분선 없음 + 카드 사이 간격(List 를 유지하면서 카드로 보이게).
    func listRowStyling() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// 기기 한 행(카드): ID 모노 15 · 사람 이름 · 표지 · 지문(4자 묶음) · 부여/해제 작은 보조 버튼(판정은 `SelfService.rolesActions`).
struct DeviceRowView: View {
    let row: SelfService.DeviceRow
    let busy: Bool
    let onRoles: (Bool) -> Void
    @Environment(\.hande) private var p

    var body: some View {
        HandeCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(row.deviceId)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(p.ink)
                        .lineLimit(1)
                    if row.isSelf { Pill(text: Strings.thisDevicePill, color: p.inkDim, fill: p.surface) }
                    if row.registrar { Pill(text: Strings.registrarPill, color: p.ember, fill: p.ember.opacity(0.16)) }
                    if row.status != SelfService.statusActive { Pill(text: Strings.revokedPill, color: p.inkDim, fill: p.ash.opacity(0.35)) }
                }
                Text(Strings.peopleNames[row.actor] ?? row.actor)
                    .font(.system(size: 15))
                    .foregroundStyle(p.inkDim)
                if !row.fingerprint.isEmpty {
                    Text(SelfService.fingerprintGroups(row.fingerprint))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(p.inkDim)
                        .textSelection(.enabled)
                }
                if row.grant || row.release {
                    Button(row.grant ? Strings.grantRegistrar : Strings.releaseRegistrar) { onRoles(row.grant) }
                        .buttonStyle(HandeSmallSecondaryButtonStyle())
                        .disabled(busy)
                        .padding(.top, 4)
                } else if row.lastRegistrar {
                    Text(Strings.lastRegistrarHint)
                        .font(.system(size: 13))
                        .foregroundStyle(p.inkDim)
                }
            }
        }
        .opacity(row.status == SelfService.statusActive ? 1 : 0.55)
    }
}

/// 작은 표지(등록 기기 · 이 기기 · 폐기됨). `fill` 을 주지 않으면 글자색 18%(옛 호출부 호환).
struct Pill: View {
    let text: String
    let color: Color
    var fill: Color? = nil
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(fill ?? color.opacity(0.18)).foregroundStyle(color).clipShape(Capsule())
    }
}

/// 승인 대기 새 기기 카드(🔔 알림·내 기기): 「새 기기가 들어오려고 합니다」 + ID 모노 18 + 요청·만료 시각 → 「지문 비교」(주) / 「무시」(보조).
struct CandidateRow: View {
    @EnvironmentObject private var model: AppModel
    let candidate: DeviceCandidate
    @State private var showApprove = false

    var body: some View {
        CandidateCard(candidate: candidate) {
            HStack(spacing: 10) {
                Button(Strings.candidateApproveButton) { showApprove = true }
                    .buttonStyle(HandePrimaryButtonStyle())
                Button(Strings.candidateIgnoreButton) { model.dismissCandidate(candidate.deviceId) }
                    .buttonStyle(HandeSecondaryButtonStyle())
            }
            .padding(.top, 6)
        }
        .fullScreenCover(isPresented: $showApprove) {
            CandidateApprovalView(candidate: candidate).environmentObject(model)
        }
    }
}

/// 후보 기기 카드(목록 행·승인 시트 공용): 15 보조 + ID 모노 18 + 「요청 HH:mm · HH:mm에 만료」 14.
struct CandidateCard<Extra: View>: View {
    let candidate: DeviceCandidate
    let extra: Extra
    @Environment(\.hande) private var p

    init(candidate: DeviceCandidate, @ViewBuilder extra: () -> Extra) {
        self.candidate = candidate
        self.extra = extra()
    }

    var body: some View {
        HandeCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(Strings.candidateIncoming)
                    .font(.system(size: 15))
                    .foregroundStyle(p.inkDim)
                Text(candidate.deviceId)
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundStyle(p.ink)
                    .lineLimit(1)
                Text(Strings.candidateTimes(created: Date(timeIntervalSince1970: TimeInterval(candidate.createdAt)),
                                            expires: Date(timeIntervalSince1970: TimeInterval(candidate.expiresAt))))
                    .font(.system(size: 14))
                    .foregroundStyle(p.inkDim)
                extra
            }
        }
    }
}

/// 지문 비교 → 승인(웹 approve 시트 relay 모드), 전체 화면. 지문은 이 기기에서 다시 계산한 값 — 릴레이 값과 다르면 목록 대신 불일치 안내(승인 불가).
/// 8행을 모두 눌러 표시해야 「승인」이 켜진다. 「다릅니다」는 후보를 무시하고 「승인하지 않았어요」 + 진단 기록 복사.
struct CandidateApprovalView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hande) private var p
    let candidate: DeviceCandidate
    @State private var fingerprint: String?
    @State private var ticked: Set<Int> = []
    @State private var busy = false
    @State private var message: String?
    @State private var outcome: Outcome?

    private enum Outcome { case approved, rejected }

    private var rows: [String] { FingerprintRows.make(fingerprint ?? "") }
    private var allTicked: Bool { !rows.isEmpty && ticked.count == rows.count }

    var body: some View {
        NavigationStack {
            ZStack {
                CampfireBackground()
                switch outcome {
                case .some(.approved): approvedView
                case .some(.rejected): rejectedView
                case .none: compareView
                }
            }
            .navigationTitle(Strings.candidatesSectionTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(p.ember)
                    }
                    .accessibilityLabel(Strings.close)
                }
            }
            .onAppear(perform: compare)
        }
    }

    // MARK: 비교

    private var compareView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CandidateCard(candidate: candidate) { EmptyView() }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Strings.approveCompareTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(p.ink)
                            .padding(.horizontal, 4)
                        if fingerprint != nil {
                            FingerprintList(groups: rows, ticked: $ticked, disabled: busy)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel(Strings.candidateFingerprintLabel)
                                .accessibilityIdentifier("approve-fingerprint")
                            Text(allTicked ? Strings.approveAllMatched : Strings.approveProgress(ticked.count, of: rows.count))
                                .font(.system(size: 14))
                                .foregroundStyle(p.inkDim)
                                .padding(.horizontal, 4)
                        }
                    }
                    warningBox
                    if let message {
                        Text(message)
                            .font(.system(size: 14))
                            .foregroundStyle(p.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            VStack(spacing: 10) {
                Button {
                    Task { await approve() }
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(p.onEmber) }
                        Text(allTicked ? Strings.approveButton : Strings.approveDisabled(rows.count))
                    }
                }
                .buttonStyle(HandePrimaryButtonStyle())
                .disabled(!allTicked || busy || fingerprint == nil)
                .accessibilityLabel(allTicked ? Strings.approveButton : Strings.approveDisabledAccessibility(rows.count))
                HStack(spacing: 10) {
                    Button(Strings.approveMismatchButton) { reject() }
                        .buttonStyle(HandeDangerButtonStyle())
                        .disabled(busy)
                    Button(Strings.approveLaterButton) { dismiss() }
                        .buttonStyle(HandeSecondaryButtonStyle())
                        .disabled(busy)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
    }

    /// 경고 상자: 선 1.5px warn 55% · 면 7% · 점 8pt + 글자 15/500. 문구 고정, 닫기 없음.
    private var warningBox: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(p.warn).frame(width: 8, height: 8).padding(.top, 7)
            Text(Strings.approveWarning)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(p.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(p.warn.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.warn.opacity(0.55), lineWidth: 1.5))
    }

    // MARK: 결과

    private var approvedView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    SeatDot(size: 12)
                    SeatDot(size: 12)
                    SeatDot(size: 12).shadow(color: p.person.opacity(0.7 * p.glow), radius: 6)
                }
                Text(Strings.approvedTitle(candidate.deviceId))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(p.ink)
                Text(Strings.approvedBody)
                    .font(.system(size: 16))
                    .foregroundStyle(p.inkDim)
                    .lineSpacing(4)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            Spacer()
            Button(Strings.approveConfirmButton) { dismiss() }
                .buttonStyle(HandePrimaryButtonStyle())
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private var rejectedView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Circle().fill(p.ash).frame(width: 12, height: 12)
                Text(Strings.rejectedTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(p.ink)
                Text(Strings.rejectedBody(candidate.deviceId))
                    .font(.system(size: 16))
                    .foregroundStyle(p.inkDim)
                    .lineSpacing(4)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 10) {
                Button(Strings.copyDiagnosticsButton) { copyDiagnostics() }
                    .buttonStyle(HandeSecondaryButtonStyle())
                Button(Strings.close) { dismiss() }
                    .buttonStyle(HandePrimaryButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // MARK: 동작

    private func compare() {
        do { fingerprint = try model.candidateFingerprint(candidate.deviceId) }
        catch { message = Strings.selfServiceFailure(error) }
    }

    private func approve() async {
        guard allTicked, fingerprint != nil else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            _ = try await model.approveCandidate(candidate.deviceId)
            outcome = .approved
        } catch {
            message = Strings.selfServiceFailure(error)
        }
    }

    /// 「다릅니다」: 승인하지 않는다 — 이 세션에서 후보를 무시하고 결과 화면(운영자에게 알리라는 안내 + 진단 기록 복사).
    private func reject() {
        model.dismissCandidate(candidate.deviceId)
        outcome = .rejected
    }

    private func copyDiagnostics() {
        #if canImport(UIKit)
        UIPasteboard.general.string = model.diagnosticsReport()
        #endif
    }
}
