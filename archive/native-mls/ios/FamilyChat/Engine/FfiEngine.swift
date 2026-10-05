// FamilyMLSCore.MlsEngine ↔ ios-ffi(uniffi) `MlsDevice` 어댑터. 앱 타깃에서만 xcframework 를 본다(Core 는 모른다).
import Foundation
import FamilyMLSCore

final class FfiEngine: MlsEngine {
    let identity: DeviceID
    private let device: MlsDevice

    init(identity: DeviceID, device: MlsDevice) {
        self.identity = identity
        self.device = device
    }

    func dispatch(_ method: EngineMethod, _ input: Data) throws -> Data {
        do {
            return try device.dispatch(method: method.rawValue, input: input)
        } catch MlsError.Rejected(let reason) {
            throw EngineError.rejected(reason)
        } catch MlsError.Invalid(let reason) {
            throw EngineError.invalid(reason)
        }
    }

    func exportState() throws -> Data { try map { try device.exportState() } }
    func publicKey() throws -> Data { try map { try device.publicKey() } }
    func fingerprint() throws -> String { try map { try device.fingerprint() } }
    func hasPending() throws -> Bool { try map { try device.hasPending() } }

    private func map<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch MlsError.Rejected(let reason) {
            throw EngineError.rejected(reason)
        } catch MlsError.Invalid(let reason) {
            throw EngineError.invalid(reason)
        }
    }
}

struct FfiEngineFactory: MlsEngineFactory {
    func create(identity: DeviceID) throws -> MlsEngine {
        FfiEngine(identity: identity, device: try MlsDevice(identity: identity))
    }
    func importState(identity: DeviceID, bytes: Data) throws -> MlsEngine {
        FfiEngine(identity: identity, device: try MlsDevice.importState(identity: identity, bytes: bytes))
    }
    static func reportedDecryptFormat() -> UInt32 { decryptFormat() }
}
