// ⛔ 정지 해제 안내 문구(§9-4 상태줄 "정지 이유", 작업지시서 DOC-3944 4절 #9). 앱 화면 전용 — NSE 소스 목록(project.yml)에 넣지 말 것.
//
// 원칙: 정지는 안전장치다(AppModel 머리말 "무음 금지"). 여기서 주는 "다음 행동"은 둘뿐이다 —
//   ① 운영자에게 알리기(사유·방·기기 ID 를 공유), ② "다시 참여 준비"(이 기기의 방 상태를 버리고 재초대를 기다림).
// 거부된 commit 을 받아들이거나 정지 사유를 사용자가 지우는 길은 없다. 사유 토큰은 웹·봇과 같다(CommitRefusalReason·SyncHaltReason).
import Foundation
import FamilyMLSCore

extension Strings {
    struct HaltGuidance: Equatable {
        /// 무엇이 일어났는지(쉬운 한국어).
        let what: String
        /// 다음에 할 일.
        let next: String
        /// "다시 참여 준비" 버튼을 보일지(방이 닫힌 경우는 아니다).
        let canPrepareRejoin: Bool
    }

    static let rejoinPrepareTitle = "다시 참여 준비"
    static let rejoinPrepareConfirm = "이 대화방의 이 기기 암호화 상태를 지우고 다시 초대받을 준비를 합니다. 지금까지 받은 메시지는 화면에 남지만, 정지된 동안 놓친 메시지는 복구되지 않습니다. 계속할까요?"
    static let rejoinPrepareDone = "준비됐습니다. 운영자(또는 다른 가족 기기)가 이 기기를 다시 초대하면 대화가 이어집니다."
    static func rejoinPrepareFailed(_ reason: String) -> String { "준비하지 못했습니다: \(reason)" }
    static let rejoinPublishFailed = "이 기기의 상태는 지웠지만 참여 요청을 올리지 못했습니다. 연결된 뒤 + → 참여 요청을 다시 눌러 주세요."
    static let reportToOperator = "운영자에게 알리기"
    static let haltedRoomsTitle = "불이 꺼진 자리"
    static let haltedDetails = "자세히"
    static let haltedReasonLabel = "사유 코드"
    /// 전역 배너 본문(#389): 사유 토큰 대신 쉬운 설명 — 토큰은 '자세히'의 「사유 코드」 줄과 운영자 보고에만 남는다.
    static func haltBannerBody(_ reason: String) -> String {
        "\(haltGuidance(reason).what) 이 대화방의 보내기와 동기화는 멈춰 있습니다. 다음에 할 일은 '자세히'에서 봅니다."
    }
    static let forgetRoomTitle = "목록에서 지우기"
    static let forgetRoomConfirm = "이 대화방을 이 기기에서 지웁니다. 이 기기에 저장된 메시지도 함께 사라집니다. 다른 기기와 릴레이에는 영향이 없고, 다시 초대받으면 새로 시작합니다. 계속할까요?"
    static func forgetRoomFailed(_ reason: String) -> String { "지우지 못했습니다: \(reason)" }
    static let haltedUnsupportedRecovery = "이 빌드의 저장소는 다시 참여 준비를 지원하지 않습니다. 설정에서 '이 기기 지우기'를 쓰세요."

    static func haltGuidance(_ reason: String) -> HaltGuidance {
        switch reason {
        case SyncHaltReason.historyGap:
            return HaltGuidance(
                what: "릴레이가 이 기기가 아직 읽지 않은 메시지를 지웠습니다. 앱이 오래 열리지 않았거나 기기가 오래 꺼져 있었을 때 생깁니다. 그 사이 메시지는 복구할 수 없습니다.",
                next: "'다시 참여 준비'를 누른 뒤 운영자나 다른 가족 기기에서 이 기기를 다시 초대하면, 그때부터 새 메시지를 받습니다.",
                canPrepareRejoin: true)
        case SyncHaltReason.removedFromRoom:
            return HaltGuidance(
                what: "다른 기기가 이 기기를 대화방에서 내보냈습니다.",
                next: "의도한 일인지 운영자에게 확인하세요. 다시 들어가려면 '다시 참여 준비'를 누르고 재초대를 기다립니다.",
                canPrepareRejoin: true)
        case SyncHaltReason.roomClosed:
            return HaltGuidance(
                what: "운영자가 이 대화방을 닫았습니다.",
                next: "이 대화방은 더 쓸 수 없습니다. 새 대화방은 운영자가 만들고 초대합니다.",
                canPrepareRejoin: false)
        case SyncHaltReason.reportFormat, SyncHaltReason.rosterUnavailable:
            return HaltGuidance(
                what: "암호화 모듈이 예상과 다른 응답을 했습니다(앱 결함일 수 있습니다).",
                next: "앱을 최신으로 업데이트하고 운영자에게 알려 주세요. 업데이트 뒤에도 같다면 '다시 참여 준비'로 재초대를 받습니다.",
                canPrepareRejoin: true)
        default:
            if CommitRefusalReason(rawValue: reason) != nil {
                return HaltGuidance(
                    what: "다른 기기가 올린 대화방 변경(초대·제거)이 규칙에 어긋나, 이 기기가 받아들이지 않고 안전을 위해 멈췄습니다.",
                    next: "운영자에게 알려 원인을 확인받으세요. 운영자가 정리한 뒤 이 기기를 다시 초대하면 '다시 참여 준비'로 돌아갑니다. 이 기기가 그 변경을 받아들이는 방법은 없습니다.",
                    canPrepareRejoin: true)
            }
            return HaltGuidance(
                what: "알 수 없는 사유(\(reason))로 멈췄습니다.",
                next: "운영자에게 알려 주세요.",
                canPrepareRejoin: true)
        }
    }

    /// 운영자에게 보낼 보고 본문(공유 시트). 키·토큰은 없다 — 방·기기 ID·사유 토큰·시각뿐.
    static func haltReport(room: String, device: String, reason: String, at date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let guidance = haltGuidance(reason)
        return """
        한데 ⛔ 정지 보고
        대화방: \(room)
        기기: \(device)
        사유: \(reason)
        설명: \(guidance.what)
        시각: \(formatter.string(from: date))
        """
    }
}
