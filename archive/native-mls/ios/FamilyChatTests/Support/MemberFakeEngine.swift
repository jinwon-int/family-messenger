// 송신 경로(`isJoined`)를 지나는 가짜 엔진 — AttachmentTests·OutgoingTests 공용(Linux 스모크 포함, UIKit 없음).
import Foundation
import FamilyMLSCore
@testable import FamilyChat

/// `FakeEngine`(AppModelTests)과 같지만 `.members` 에 이 기기가 든 roster 프레임을 돌려준다 — 송신 경로(`isJoined`)를 지나기 위해.
/// 프레임 = u32le count ‖ (u32le idLen ‖ id ‖ 32B key)*  (CommitPolicy.parseRosterFrame).
final class MemberFakeEngine: MlsEngine {
    let identity: DeviceID
    var state: Data
    init(identity: DeviceID, state: Data = Data("s0".utf8)) { self.identity = identity; self.state = state }
    func dispatch(_ method: EngineMethod, _ input: Data) throws -> Data {
        if method == .members {
            var frame = Data()
            func u32(_ v: Int) { var le = UInt32(v).littleEndian; frame.append(Data(bytes: &le, count: 4)) }
            u32(1); u32(identity.utf8.count); frame.append(Data(identity.utf8)); frame.append(Data(repeating: 0xab, count: 32))
            return frame
        }
        if let policy = FakePolicyWire.respond(method, input) { return policy }
        state.append(1)
        return Data("ct:".utf8) + input
    }
    func exportState() throws -> Data { state }
    func publicKey() throws -> Data { Data(repeating: 0xab, count: 32) }
    func fingerprint() throws -> String { String(repeating: "f", count: 64) }
    func hasPending() throws -> Bool { false }
}

struct MemberFakeFactory: MlsEngineFactory {
    func create(identity: DeviceID) throws -> MlsEngine { MemberFakeEngine(identity: identity) }
    func importState(identity: DeviceID, bytes: Data) throws -> MlsEngine { MemberFakeEngine(identity: identity, state: bytes) }
}

/// 가짜 엔진들이 함께 쓰는 정책 메서드 대역(#574, FakeEngine·MemberFakeEngine): `policy_fingerprint` = 어느 공개키든 가짜 신원의 지문
/// (`fingerprint()` 와 같은 "f"×64 — 같은 가짜 엔진이 올린 후보의 지문과 맞는다), `sign_approval`·`sign_roles` = 파사드 프레임
/// `u32le n ‖ canonical(입력 그대로) ‖ 64바이트 서명(0x5a)`(SelfService.signatureHex). 그 밖의 메서드는 nil.
enum FakePolicyWire {
    static let fingerprint = String(repeating: "f", count: 64)
    static let signatureByte: UInt8 = 0x5a

    static func respond(_ method: EngineMethod, _ input: Data) -> Data? {
        switch method {
        case .policyFingerprint:
            return Data(fingerprint.utf8)
        case .signApproval, .signRoles:
            var frame = Data()
            var n = UInt32(input.count).littleEndian
            frame.append(Data(bytes: &n, count: 4)); frame.append(input); frame.append(Data(repeating: signatureByte, count: 64))
            return frame
        default:
            return nil
        }
    }
}

