import XCTest
@testable import FamilyMLSCore

final class FramingTests: XCTestCase {
    func testEncryptInputMatchesBotFraming() {
        let out = Framing.encryptInput(room: "room-a", clientId: "owner-iphone", plaintext: Data("hi".utf8))
        var expected = Data([6, 0, 0, 0]); expected.append(Data("room-a".utf8))
        expected.append(Data([12, 0, 0, 0])); expected.append(Data("owner-iphone".utf8))
        expected.append(Data("hi".utf8))
        XCTAssertEqual(out, expected)
    }

    func testDecryptInputAndOutputRoundtrip() throws {
        let input = Framing.decryptInput(room: "room-a", ciphertext: Data([9, 9, 9]))
        XCTAssertEqual(input.prefix(4), Data([6, 0, 0, 0]))
        XCTAssertEqual(input.suffix(3), Data([9, 9, 9]))

        var framed = Data([8, 0, 0, 0]); framed.append(Data("owner-pc".utf8))
        framed.append(Data([8, 0, 0, 0])); framed.append(Data("owner-pc".utf8))
        framed.append(Data("안녕".utf8))
        let parsed = try Framing.parseDecrypted(framed)
        XCTAssertEqual(parsed, Framing.Decrypted(senderDevice: "owner-pc", clientId: "owner-pc", plaintext: Data("안녕".utf8)))
    }

    func testTruncatedDecryptOutputIsRejected() {
        XCTAssertThrowsError(try Framing.parseDecrypted(Data([8, 0, 0, 0, 1, 2])))
        XCTAssertThrowsError(try Framing.parseDecrypted(Data([1, 2])))
    }

    func testDecryptFormatPin() {
        XCTAssertEqual(Framing.decryptFormat, 2)
    }
}
