// 앱 전용 문구(오류 매핑). `Strings.swift` 는 NSE 타깃에도 컴파일되는데 `MembershipError`(RoomMembership.swift)는 앱에만 있어
// 여기에 둔다 — NSE 소스 목록(project.yml)에 이 파일을 넣지 말 것.
import Foundation
import FamilyMLSCore

extension Strings {
    /// 참여 요청·방 만들기·초대 실패를 사람이 읽을 문구로(원인별 다음 행동 포함). 모르는 오류는 원문.
    static func membershipFailure(_ error: Error) -> String {
        switch error {
        case MembershipError.noKeyPackage(let device):
            return "\(device) 기기의 키가 없습니다 — 이 대화방에 '참여 요청'을 하지 않았고 로비 키도 없습니다(또는 모두 쓰였습니다). 그 기기에서 앱을 한 번 열거나(로비 키 보충) + → 참여 요청 후 다시 초대하세요."
        case MembershipError.alreadyInGroup:
            return "이 기기에 이미 있는 대화방입니다."
        case MembershipError.notInGroup:
            return "이 대화방의 멤버가 아니라 초대할 수 없습니다. 멤버인 기기에서 초대하세요."
        case MembershipError.ownCommitNotMerged:
            return "초대를 올렸지만 확인이 끝나지 않았습니다. 목록을 새로고침한 뒤 다시 시도하세요."
        case MembershipError.inviteFrame:
            return "초대 데이터를 만들지 못했습니다(암호화 모듈 응답 형식). 앱을 업데이트해 주세요."
        case RelayError.cas:
            return "다른 기기가 먼저 대화방을 바꿨습니다. 새로고침한 뒤 다시 시도하세요."
        case RelayError.unauthorized:
            return sessionExpired
        case RelayError.refused(let code, _):
            return "릴레이가 거부했습니다(\(code))."
        case RelayError.network:
            return "릴레이에 닿지 않습니다. 연결을 확인하고 다시 시도하세요."
        default:
            return "\(error)"
        }
    }
}
