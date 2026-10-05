// 계약 1b — 파사드 와이어 프레이밍 (CONTRACTS.md §1). 봇 `tests/native_facade_link.rs`·ios-ffi 테스트와 동일 규칙.
//   encrypt 입력 : u32le len ‖ room ‖ u32le len ‖ client_id ‖ plaintext
//   decrypt 입력 : u32le len ‖ room ‖ ciphertext
//   decrypt 출력 : (DECRYPT_FORMAT 2) u32le len ‖ sender_device ‖ u32le len ‖ client_id ‖ plaintext
import Foundation

public enum Framing {
    /// 호스트 파서가 핀하는 파사드 `decrypt_format()` 값. 엔진이 다른 값을 보고하면 앱은 시작을 거부한다.
    public static let decryptFormat: UInt32 = 2

    public struct Decrypted: Equatable {
        public let senderDevice: DeviceID
        public let clientId: String
        public let plaintext: Data
        public init(senderDevice: DeviceID, clientId: String, plaintext: Data) {
            self.senderDevice = senderDevice; self.clientId = clientId; self.plaintext = plaintext
        }
    }

    public enum FramingError: Error, Equatable { case truncated, badLength }

    public static func encryptInput(room: RoomID, clientId: String, plaintext: Data) -> Data {
        var out = Data()
        append(&out, room)
        append(&out, clientId)
        out.append(plaintext)
        return out
    }

    public static func decryptInput(room: RoomID, ciphertext: Data) -> Data {
        var out = Data()
        append(&out, room)
        out.append(ciphertext)
        return out
    }

    public static func parseDecrypted(_ data: Data) throws -> Decrypted {
        var offset = 0
        let sender = try readString(data, &offset)
        let clientId = try readString(data, &offset)
        return Decrypted(senderDevice: sender, clientId: clientId, plaintext: data.subdata(in: offset..<data.count))
    }

    // MARK: - helpers

    static func append(_ out: inout Data, _ s: String) {
        let bytes = Data(s.utf8)
        var len = UInt32(bytes.count).littleEndian
        out.append(Data(bytes: &len, count: 4))
        out.append(bytes)
    }

    static func readString(_ data: Data, _ offset: inout Int) throws -> String {
        guard data.count - offset >= 4 else { throw FramingError.truncated }
        let lenBytes = data.subdata(in: offset..<(offset + 4))
        let len = Int(lenBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        offset += 4
        guard len >= 0, data.count - offset >= len else { throw FramingError.truncated }
        let slice = data.subdata(in: offset..<(offset + len))
        offset += len
        guard let s = String(data: slice, encoding: .utf8) else { throw FramingError.badLength }
        return s
    }
}
