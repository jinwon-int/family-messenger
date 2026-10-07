// 기기 등록 요청 (#276 L3 5번) — 릴레이가 403 `device_subject_mismatch` 로 이 기기를 받지 않을 때(정책 체인에 아직 없음)
// "운영자 등록 대기" 화면이 보여 줄 JSON. 키는 relay-app §1 `enroll-info`·운영자 CLI `-enroll-first`/`-add-device` 입력과
// 글자 그대로 같다: device_id · actor · subject · signing_key · fingerprint. 비밀은 없다(공개키와 그 지문뿐).
import Foundation

public struct EnrollmentRequest: Codable, Equatable {
    public var deviceId: DeviceID
    /// 기기 ID 의 첫 `-` 앞(relay-app `actorOf`, `MessageRecord.senderActor` 와 같은 규칙).
    public var actor: String
    /// CF Access `sub`. 앱이 로그인 뒤 알면 채우고, 모르면 운영자가 채운다.
    public var subject: String
    /// 공개 서명키 lowercase hex.
    public var signingKey: String
    /// sha256(signing key) lowercase hex — 사람이 눈으로 비교하는 값(DEVICES-V4).
    public var fingerprint: String

    enum CodingKeys: String, CodingKey {
        case actor, subject, fingerprint
        case deviceId = "device_id", signingKey = "signing_key"
    }

    public init(deviceId: DeviceID, actor: String, subject: String, signingKey: String, fingerprint: String) {
        self.deviceId = deviceId; self.actor = actor; self.subject = subject
        self.signingKey = signingKey; self.fingerprint = fingerprint
    }

    /// 엔진의 공개 정보로 만든다(키 자체는 공개키뿐).
    public init(engine: MlsEngine, subject: String) throws {
        let id = engine.identity
        self.init(deviceId: id, actor: Self.actor(of: id), subject: subject,
                  signingKey: try engine.publicKey().map { String(format: "%02x", $0) }.joined(),
                  fingerprint: try engine.fingerprint())
    }

    public static func actor(of device: DeviceID) -> String {
        String(device.split(separator: "-", maxSplits: 1).first ?? Substring(device))
    }

    /// 운영자에게 전달할 JSON(키 정렬·들여쓰기 — 사람이 읽고 붙여 넣는다).
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
