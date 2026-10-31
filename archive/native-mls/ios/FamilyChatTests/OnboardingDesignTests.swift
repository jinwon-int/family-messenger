import XCTest
import SwiftUI
import FamilyMLSCore
@testable import FamilyChat

/// 디자인 2차-A(2026-10-31) 온보딩·새 기기 승인: 지문 행 묶음(OnboardingKit `FingerprintRows`)과 문구 — 규칙은 docs/design/HANDE-DESIGN-SYSTEM.md §A1~A2.
final class OnboardingDesignTests: XCTestCase {
    private let hex64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    /// 64 hex → 4자 묶음 16개를 둘씩 짝지어 「xxxx xxxx」 8행 — 등록 화면과 승인 시트가 같은 행·같은 번호를 보인다(§A1 ①).
    func testSixtyFourHexMakesEightPairedRows() {
        let rows = FingerprintRows.make(hex64)
        XCTAssertEqual(rows.count, 8)
        for row in rows {
            XCTAssertEqual(row.count, 9, "「xxxx xxxx」 — \(row)")
            let halves = row.split(separator: " ")
            XCTAssertEqual(halves.count, 2)
            XCTAssertTrue(halves.allSatisfy { $0.count == 4 })
        }
        XCTAssertEqual(rows[0], "0123 4567")
        XCTAssertEqual(rows[7], "89ab cdef")
        XCTAssertEqual(rows.joined(separator: " ").replacingOccurrences(of: " ", with: ""), hex64, "행을 다 이으면 원래 지문")
        XCTAssertEqual(rows.joined(separator: " "), SelfService.fingerprintGroups(hex64), "묶음·순서는 Core 와 같다")
    }

    /// 짧은 입력은 있는 만큼만 — 채우지 않는다. 공백은 Core 묶음 규칙대로 무시.
    func testShortInputIsGroupedWithoutPadding() {
        XCTAssertEqual(FingerprintRows.make(""), [])
        XCTAssertEqual(FingerprintRows.make("abcd"), ["abcd"])
        XCTAssertEqual(FingerprintRows.make("abcdef"), ["abcd ef"])
        XCTAssertEqual(FingerprintRows.make("abcd1234ff"), ["abcd 1234", "ff"])
        XCTAssertEqual(FingerprintRows.make("abcd 1234 ffff"), ["abcd 1234", "ffff"])
        XCTAssertEqual(FingerprintRows.perRow, 2)
    }

    /// 진행 막대는 4칸(서버 → 이름 → 로그인 → 등록), 라벨은 「4단계 중 n단계」.
    func testStepBarCountAndLabel() {
        XCTAssertEqual(Strings.onboardingSteps, 4)
        XCTAssertEqual(Strings.onboardingStep(1, of: 4), "4단계 중 1단계")
        XCTAssertEqual(Strings.onboardingStep(4, of: Strings.onboardingSteps), "4단계 중 4단계")
        XCTAssertEqual(StepBar(step: 2).total, 4)
        XCTAssertEqual(StepBar(step: 3, of: 5).total, 5)
    }

    /// 첫 화면 선언·설명은 1줄 + 「자세히」(2차-A 규칙), 옛 문구는 그대로 남는다.
    func testServerAndActorCopy() {
        XCTAssertTrue(Strings.serverDeclaration.contains("회원가입이 없습니다"))
        XCTAssertTrue(Strings.serverDeclaration.contains("가족 운영자가 등록합니다"))
        XCTAssertFalse(Strings.serverAddressHint.contains("\n"), "안내는 1줄")
        XCTAssertTrue(Strings.serverAddressDetail.contains("http 주소는 쓸 수 없습니다"))
        XCTAssertEqual(Strings.onboardingMore, "자세히")
        XCTAssertEqual(Strings.actorStepInvalid, "영문 소문자·숫자 2~16자로 써 주세요")
        XCTAssertFalse(Strings.actorStepHint.contains("\n"))
        XCTAssertTrue(Strings.actorStepDetail.contains("2~16자"))
        XCTAssertFalse(Strings.actorInvalid.isEmpty, "모델이 쓰는 옛 문구는 유지")
    }

    /// 등록 대기 문구에서 기술값(403 device_subject_mismatch)은 빠지고 진단 토큰으로만 남는다. 형제 기기 모드는 만료 시각(HH:mm)만.
    func testEnrollWaitingCopyHasNoTechnicalToken() {
        XCTAssertFalse(Strings.enrollWaitingOperator.contains("403"))
        XCTAssertFalse(Strings.enrollWaitingSibling.contains("403"))
        XCTAssertFalse(Strings.enrollStepLine.contains("device_subject_mismatch"))
        XCTAssertEqual(Strings.enrollDiagnosticToken, "403 device_subject_mismatch")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let at = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 21, minute: 40))!
        XCTAssertEqual(Strings.clockLabel(at), "21:40")
        XCTAssertEqual(Strings.enrollWaitingSiblingUntil(at), "다른 기기의 승인을 기다리는 중 · 21:40까지")
        let created = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 21, minute: 10))!
        XCTAssertEqual(Strings.candidateTimes(created: created, expires: at), "요청 21:10 · 21:40에 만료")
        XCTAssertEqual(Strings.kindlingTitle, "불을 피우는 중…")
        XCTAssertEqual(Strings.kindlingBody, "암호 키를 만들고 있어요")
    }

    /// 새 기기 승인: 8행을 모두 맞추기 전 「승인」 문구·VoiceOver, 진행 문구, 결과 문구(글자로만).
    func testApprovalGateCopy() {
        XCTAssertEqual(Strings.approveDisabled(8), "8줄을 모두 맞춰 보세요")
        XCTAssertEqual(Strings.approveDisabledAccessibility(8), "8줄을 모두 맞춘 뒤 승인할 수 있습니다")
        XCTAssertEqual(Strings.approveProgress(3, of: 8), "같으면 눌러 표시하세요 · 3 / 8")
        XCTAssertEqual(Strings.approveAllMatched, "모두 맞췄어요")
        XCTAssertEqual(Strings.approveButton, "승인")
        XCTAssertEqual(Strings.approveMismatchButton, "다릅니다")
        XCTAssertEqual(Strings.approveLaterButton, "나중에")
        XCTAssertEqual(Strings.approvedTitle("jiyu-ipad"), "jiyu-ipad를 승인했어요")
        XCTAssertEqual(Strings.rejectedBody("jiyu-ipad"), "jiyu-ipad는 들어오지 못합니다. 운영자에게 지문이 달랐다고 알려 주세요.")
        XCTAssertEqual(Strings.fingerprintRowLabel(3, "0123 4567", ticked: false), "3번, 0123 4567, 맞춤 표시 안 됨")
        XCTAssertEqual(Strings.fingerprintRowLabel(3, "0123 4567", ticked: true), "3번, 0123 4567, 맞춤 표시 됨")
        XCTAssertEqual(Strings.fingerprintRowLabel(1, "0123 4567", ticked: nil), "1번, 0123 4567")
        XCTAssertTrue(Strings.approveWarning.contains("승인하지 말고"))
    }

    /// 승인 시트가 실제 지문으로 만드는 행 수 = 「n줄을 모두 맞춰 보세요」의 n — 64 hex 면 8.
    func testGateCountFollowsRowCount() {
        let rows = FingerprintRows.make(hex64)
        XCTAssertEqual(Strings.approveDisabled(rows.count), "8줄을 모두 맞춰 보세요")
        var ticked: Set<Int> = []
        for index in rows.indices { ticked.insert(index) }
        XCTAssertEqual(ticked.count, rows.count)
    }
}
