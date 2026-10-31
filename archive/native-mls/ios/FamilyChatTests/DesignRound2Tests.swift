import XCTest
import SwiftUI
import FamilyMLSCore
@testable import FamilyChat

/// 디자인 2차-A(2026-10-31) 2c~2f: 빈 상태·순서 편집·대화방 상태·설정·알림함·정지 화면의 문구와 공용 부품(순수 값만).
final class DesignRound2Tests: XCTestCase {
    /// 2c: 빈 상태는 건수 숫자 대신 「있어요」, 순서 모드 안내는 한 줄.
    func testEmptyStateAndOrderModeCopy() {
        XCTAssertEqual(Strings.campfireEmpty, "아직 피운 모닥불이 없습니다")
        XCTAssertEqual(Strings.emptyRoomsHint, "운영자가 초대하면 여기에 자리가 생겨요.")
        XCTAssertFalse(Strings.invitesInBellPlain.contains(where: \.isNumber), "건수 숫자 없이 「있어요」")
        XCTAssertEqual(Strings.orderModeTitle, "자리 순서")
        XCTAssertEqual(Strings.orderHint, "끌어서 순서를 바꾸세요. 이 기기에만 저장돼요.")
        XCTAssertEqual(Strings.orderDone, "완료")
        XCTAssertEqual(Strings.orderPinnedNote, "맨 위 고정")
        XCTAssertNotNil(SVGPathData.parse(EmptyCampfireArt.logs), "빈 상태 장작 path 가 끝까지 읽힌다")
    }

    /// 2d: 전송 상태는 글자로 남고(색만이 아니라), 새 메시지 알약은 개수 없이, 연결 배너는 사람 말.
    func testRoomStateCopy() {
        XCTAssertEqual(Strings.outgoingFailed, "전송 안 됨")
        XCTAssertEqual(Strings.outgoingRetry, "다시 보내기")
        XCTAssertEqual(Strings.outgoingQueued, "연결되면 보냅니다")
        XCTAssertEqual(Strings.outgoingAttachment, "사진·파일 보내는 중")
        XCTAssertEqual(Strings.newMessagesBelow, "새 메시지", "화살표는 아이콘으로 — 글자에 개수·기호 없음")
        XCTAssertEqual(Strings.relayUnreachableBanner, "릴레이에 닿지 않아요 — 연결되면 보낼게요")
        XCTAssertEqual(OutgoingAttachmentPlaceholder.size, CGSize(width: 200, height: 150))
    }

    /// 2e 설정: 테마 세그먼트 라벨·힌트, 잠금화면 미리보기 짧은 값(행 값은 짧게, 긴 설명판은 접근성·측정용으로 유지).
    func testSettingsCopy() {
        XCTAssertEqual(Strings.themeChipNight, "밤")
        XCTAssertEqual(Strings.themeChipDay, "낮불")
        XCTAssertTrue(Strings.themeNightHint.contains("시스템 다크/라이트를 따르지 않습니다"))
        XCTAssertTrue(Strings.themeDayHint.contains("e-ink"))
        XCTAssertEqual(Strings.lockPreviewShort(.always), "항상")
        XCTAssertEqual(Strings.lockPreviewShort(.whenUnlocked), "잠금 해제 시")
        XCTAssertEqual(Strings.lockPreviewShort(.never), "안 함")
        XCTAssertEqual(Strings.lockPreviewShort(.off), "꺼짐")
        XCTAssertEqual(Strings.lockPreviewShort(.unknown), "확인 전")
        XCTAssertTrue(Strings.lockPreview(.always).hasPrefix("항상"), "긴 설명판은 그대로")
        XCTAssertEqual(Strings.settingsDanger, "위험 구역")
        XCTAssertEqual(Strings.wipeTitle, "이 기기 지우기")
        XCTAssertEqual(Strings.deleteDataGuide, "데이터 삭제 안내")
        XCTAssertEqual(Strings.logoutHintPlain, "세션만 지워요. 다시 로그인하면 같은 기기로 이어집니다.")
    }

    /// 2e 알림함: 실패 횟수는 사람 말(한·두·세 번), 넷부터 숫자. 기술 사유(Welcome 등)는 카드에 없다.
    func testInviteCardCopy() {
        XCTAssertEqual(Strings.countWord(1), "한 번")
        XCTAssertEqual(Strings.countWord(2), "두 번")
        XCTAssertEqual(Strings.countWord(3), "세 번")
        XCTAssertEqual(Strings.countWord(4), "4번")
        XCTAssertEqual(Strings.countWord(0), "한 번", "0 은 오지 않지만 「한 번」으로 둔다")
        XCTAssertEqual(Strings.inviteAutoFailedPlain(2), "자동 수락이 두 번 안 됐어요 — 키는 그대로라 다시 시도할 수 있어요.")
        XCTAssertFalse(Strings.inviteAutoFailedPlain(2).contains("Welcome"))
        XCTAssertEqual(Strings.inviteCardBody("할머니댁"), "운영자가 「할머니댁」 자리에 이 기기를 초대했어요.")
        XCTAssertEqual(Strings.inviteFailedTitle("가족 여행"), "「가족 여행」 자리에 들어가지 못했어요.")
        XCTAssertEqual(Strings.inviteKickerLine("방금"), "새 자리 초대 · 방금")
        XCTAssertEqual(Strings.inviteKickerLine(nil), "새 자리 초대")
        XCTAssertEqual(Strings.inviteKickerLine(""), "새 자리 초대")
        XCTAssertEqual(Strings.notifyEmpty, "새 알림이 없어요")
        XCTAssertEqual(Strings.notifyEmptyBody, "받은 초대와 수락 상태가 여기 모입니다.")
        XCTAssertEqual(Strings.notifyCopyLogsShort, "기록 복사")
        XCTAssertEqual(Strings.notifyCopied, "복사했어요")
        XCTAssertFalse(Strings.notifyHint.contains("Welcome"), "기술어 없이")
    }

    /// 2f: ⛔ 이모지 없음 — 제목·보고 어디에도. 큰 제목은 두 줄.
    func testHaltedCopyHasNoStopSignEmoji() {
        XCTAssertEqual(Strings.haltedTitle, "이 기기의 대화가 멈췄어요")
        XCTAssertFalse(Strings.haltedTitle.contains("⛔"))
        XCTAssertEqual(Strings.haltedDeviceTitle, "이 기기의 대화가\n멈췄어요")
        XCTAssertFalse(Strings.haltReport(room: "r", device: "d", reason: SyncHaltReason.roomClosed).contains("⛔"))
        XCTAssertEqual(Strings.roomClosedTitle, "운영자가 이 자리를 닫았어요")
        XCTAssertTrue(Strings.roomClosedBody.contains("운영자에게"))
        XCTAssertTrue(Strings.haltedDeviceHint.contains("운영자에게"))
    }

    /// 공용 부품: 배너 종류 2개(info/warn), 토스트 밤 면 #1C2136, 위험 버튼(OnboardingKit)·설정 카드가 존재한다(컴파일 확인).
    func testThemeParts() {
        XCTAssertNotEqual(HandeBanner.Kind.info, HandeBanner.Kind.warn)
        XCTAssertEqual(HandeToast.nightFill, Color(hande: 0x1C2136))
        _ = HandeDangerButtonStyle()
        _ = HandeBanner(kind: .warn, text: Strings.relayUnreachableBanner)
        _ = SectionHeader(Strings.settingsAbout)
        _ = SectionCard { SectionRow(divider: false) { Text("row") } }
        _ = DotsRow(color: HandePalette.night.ash, size: 12)
    }
}
