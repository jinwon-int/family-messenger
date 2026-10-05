// 시뮬레이터에서 Rust 파사드를 실제로 실행하는 게이트: ios-ffi tests/host_roundtrip.rs 와 같은 시나리오·같은 프레이밍.
import XCTest
@testable import FamilyMLSSpike

final class RoundtripTests: XCTestCase {
    // encrypt: u32le len ‖ room ‖ u32le len ‖ client_id ‖ plaintext
    func frame(_ room: String, _ clientId: String, _ plaintext: Data) -> Data {
        var out = Data()
        out.append(le(room.utf8.count)); out.append(Data(room.utf8))
        out.append(le(clientId.utf8.count)); out.append(Data(clientId.utf8))
        out.append(plaintext)
        return out
    }
    // decrypt in: u32le len ‖ room ‖ ciphertext
    func frameRoom(_ room: String, _ ciphertext: Data) -> Data {
        var out = Data(); out.append(le(room.utf8.count)); out.append(Data(room.utf8)); out.append(ciphertext); return out
    }
    // decrypt out (format 2): u32le len ‖ sender_device ‖ u32le len ‖ client_id ‖ plaintext
    func frameDecrypt(_ sender: String, _ clientId: String, _ plaintext: Data) -> Data {
        var out = Data()
        out.append(le(sender.utf8.count)); out.append(Data(sender.utf8))
        out.append(le(clientId.utf8.count)); out.append(Data(clientId.utf8))
        out.append(plaintext)
        return out
    }
    func le(_ n: Int) -> Data { withUnsafeBytes(of: UInt32(n).littleEndian) { Data($0) } }

    func testTwoDevicesRoundtripOnSimulator() throws {
        XCTAssertEqual(decryptFormat(), 2)
        let owner = try MlsDevice(identity: "owner-iphone")
        let peer = try MlsDevice(identity: "owner-pc")

        let kp = try peer.dispatch(method: "key_package", input: Data())
        _ = try owner.dispatch(method: "create", input: Data())
        let welcome = try owner.dispatch(method: "invite", input: kp)
        _ = try peer.dispatch(method: "join", input: welcome)

        let ct = try owner.dispatch(method: "encrypt", input: frame("room-a", "owner-iphone", Data("안녕 PC".utf8)))
        let pt = try peer.dispatch(method: "decrypt", input: frameRoom("room-a", ct))
        XCTAssertEqual(pt, frameDecrypt("owner-iphone", "owner-iphone", Data("안녕 PC".utf8)))

        let back = try peer.dispatch(method: "encrypt", input: frame("room-a", "owner-pc", Data("안녕 아이폰".utf8)))
        let got = try owner.dispatch(method: "decrypt", input: frameRoom("room-a", back))
        XCTAssertEqual(got, frameDecrypt("owner-pc", "owner-pc", Data("안녕 아이폰".utf8)))
    }

    func testExportImportKeepsIdentityAndRejectsForeign() throws {
        let device = try MlsDevice(identity: "owner-iphone")
        let fp = try device.fingerprint()
        XCTAssertEqual(fp.count, 64)
        let state = try device.exportState()
        XCTAssertThrowsError(try MlsDevice.importState(identity: "owner-pc", bytes: state))
        let resumed = try MlsDevice.importState(identity: "owner-iphone", bytes: state)
        XCTAssertEqual(try resumed.fingerprint(), fp)
    }

    func testRejectedOperationRollsBack() throws {
        let device = try MlsDevice(identity: "owner-iphone")
        _ = try device.dispatch(method: "create", input: Data())
        let fp = try device.fingerprint()
        XCTAssertThrowsError(try device.dispatch(method: "join", input: Data("not a welcome".utf8))) { error in
            guard case MlsError.Rejected = error else { return XCTFail("expected Rejected, got \(error)") }
        }
        XCTAssertEqual(try device.fingerprint(), fp)
        XCTAssertFalse(try device.dispatch(method: "key_package", input: Data()).isEmpty)
    }
}
