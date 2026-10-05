// 계약 1 — MLS 엔진 경계 (CONTRACTS.md §1).
// ios-ffi `MlsDevice`(uniffi)를 그대로 비추는 프로토콜. 앱 타깃이 xcframework 로 구현하고,
// Core 의 모든 로직·테스트는 이 프로토콜(가짜 엔진)만 본다. 메서드 이름은 durable-worker `allowed`
// (web/durable-worker.js)·봇·ios-ffi `METHODS` 와 글자 그대로 같다.
import Foundation

public typealias RoomID = String
public typealias DeviceID = String

public enum EngineError: Error, Equatable {
    /// 파사드가 거부(사유 = 파사드 고정 문자열). 호출자는 기기 객체가 연산 전 스냅샷으로 복원됐다고 가정해도 된다(ios-ffi 계약).
    case rejected(String)
    /// 호스트 전제 위반(알 수 없는 메서드 등).
    case invalid(String)
}

/// `dispatch` 메서드. rawValue 가 와이어 이름이다.
public enum EngineMethod: String, CaseIterable {
    case keyPackage = "key_package"
    case deleteKeyPackage = "delete_key_package"
    case create
    case invite
    case inviteWithCommit = "invite_with_commit"
    case join
    case encrypt
    case decrypt
    case remove
    case removePending = "remove_pending"
    case commit
    case mergePending = "merge_pending"
    case clearPending = "clear_pending"
    case stageCommit = "stage_commit"
    case mergeStaged = "merge_staged"
    case discardStaged = "discard_staged"
    // L2 가 파사드 `Session` 공개 API 로 추가하는 것(CONTRACTS.md §2). 추가 전에는 엔진이 `.invalid` 를 던진다.
    case members
    case membersAfterPending = "members_after_pending"
    case policyFingerprint = "policy_fingerprint"
    case signApproval = "sign_approval"
}

public protocol MlsEngine: AnyObject {
    var identity: DeviceID { get }
    func dispatch(_ method: EngineMethod, _ input: Data) throws -> Data
    /// 전체 상태 스냅샷(봉인 전 평문 바이트). 저장은 `MlsStateStore` 가 한다.
    func exportState() throws -> Data
    func publicKey() throws -> Data
    /// sha256(publicKey) lowercase hex — DEVICES-V4 의 지문.
    func fingerprint() throws -> String
    func hasPending() throws -> Bool
}

public protocol MlsEngineFactory {
    func create(identity: DeviceID) throws -> MlsEngine
    func importState(identity: DeviceID, bytes: Data) throws -> MlsEngine
}
