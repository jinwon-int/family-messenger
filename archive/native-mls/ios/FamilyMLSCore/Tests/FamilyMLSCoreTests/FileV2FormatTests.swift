// file-v2 설명자 엄격 검증(#499, FILE-V2.md §1) — 웹 `file-v2.js parseDescriptor`·안드로이드 `FileV2Test` 와 같은 판정.
// 웹보다 엄격한 점(중복 키·BOM·짝 없는 서로게이트 거부)도 고정한다.
import XCTest
@testable import FamilyMLSCore

final class FileV2FormatTests: XCTestCase {
    static let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"   // bytes 0..31
    static let nonce = "AAECAwQFBgcICQoL"                            // bytes 0..11 (key 의 앞부분과 같은 문자열)
    static let blob = "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"
    static let clientId = "file-v2-0f8fad5b-d9cb-469f-a165-70867728950e"
    static let minimal = #"{"v":2,"blob":"\#(blob)","size":2481920,"key":"\#(key)","nonce":"\#(nonce)"}"#
    static let nonceField = #""nonce":"\#(nonce)""#

    static func desc(_ fields: String) -> String { #"{"v":2,"blob":"\#(blob)","size":10,"key":"\#(key)","nonce":"\#(nonce)"\#(fields)}"# }
    private func parse(_ json: String) throws -> FileV2Format.Descriptor { try FileV2Format.parseDescriptor(Data(json.utf8)) }
    private func reason(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do { _ = try parse(json); XCTFail("accepted: \(json.prefix(80))", file: file, line: line); return nil }
        catch let e as FileV2Format.Rejected { return e.reason }
        catch { XCTFail("\(error)", file: file, line: line); return nil }
    }

    func testMinimalDescriptor() throws {
        let d = try parse(Self.minimal)
        XCTAssertEqual(d.blob, Self.blob)
        XCTAssertEqual(d.size, 2_481_920)
        XCTAssertEqual(d.key, Data((0..<32).map { UInt8($0) }))
        XCTAssertEqual(d.nonce, Data((0..<12).map { UInt8($0) }))
        XCTAssertNil(d.mime); XCTAssertNil(d.name); XCTAssertNil(d.width); XCTAssertNil(d.height)
        XCTAssertFalse("\(d)".contains(Self.key), "description must not leak the key")
        XCTAssertFalse(String(reflecting: d).contains(Self.key))
    }

    func testOptionalFieldsEscapesAndIntegerForms() throws {
        let d = try parse(" \n" + Self.desc(#","mime":"image/jpeg","name":"사진 📷.jpg","w":4032,"h":3024"#) + "\r\n\t")
        XCTAssertEqual(d.mime, "image/jpeg")
        XCTAssertEqual(d.name, "사진 📷.jpg")
        XCTAssertEqual(d.width, 4032); XCTAssertEqual(d.height, 3024)
        XCTAssertEqual(try parse(Self.desc(#","name":"a\/b""#)).name, "a/b")
        XCTAssertEqual(try parse(Self.desc(#","name":"가""#)).name, "가")
        XCTAssertEqual(try parse(#"{"v":2.0,"blob":"\#(Self.blob)","size":1e1,"key":"\#(Self.key)","nonce":"\#(Self.nonce)"}"#).size, 10)
    }

    func testLimits() throws {
        XCTAssertEqual(try parse(Self.minimal.replacingOccurrences(of: "2481920", with: "52428800")).size, FileV2Format.maxFileBytes)
        for bad in ["52428801", "0", "1.5", "-1", "\"10\""] {
            XCTAssertEqual(reason(Self.minimal.replacingOccurrences(of: "2481920", with: bad)), "size", bad)
        }
        XCTAssertNotNil(reason(Self.minimal.replacingOccurrences(of: "2481920", with: "1e400")))   // 무한대 — 어느 단계든 거부
        XCTAssertEqual(try parse(Self.desc(#","w":20000"#)).width, 20000)
        XCTAssertEqual(reason(Self.desc(#","w":20001"#)), "w")
        XCTAssertEqual(reason(Self.desc(#","h":0"#)), "h")
        XCTAssertNotNil(try parse(Self.desc(#","name":"\#(String(repeating: "가", count: 255))""#)).name)
        XCTAssertEqual(reason(Self.desc(#","name":"\#(String(repeating: "가", count: 256))""#)), "name")
        XCTAssertNotNil(try parse(Self.desc(#","name":"\#(String(repeating: "📷", count: 255))""#)).name, "counted in code points")
        XCTAssertNotNil(try parse(Self.desc(#","mime":"a/\#(String(repeating: "b", count: 64))""#)).mime)
        XCTAssertEqual(reason(Self.desc(#","mime":"a/\#(String(repeating: "b", count: 65))""#)), "mime")
    }

    func testShapeRejections() {
        XCTAssertEqual(reason(Self.desc(#","extra":1"#)), "unknown key")
        XCTAssertEqual(reason(Self.desc(#","__proto__":{}"#)), "unknown key")
        XCTAssertEqual(reason(#"{"v":2,"blob":"\#(Self.blob)","size":10,"key":"\#(Self.key)"}"#), "missing nonce")
        XCTAssertEqual(reason(Self.minimal.replacingOccurrences(of: #""v":2"#, with: #""v":3"#)), "version")
        XCTAssertEqual(reason(Self.minimal.replacingOccurrences(of: #""v":2"#, with: #""v":"2""#)), "version")
        XCTAssertEqual(reason(Self.minimal.replacingOccurrences(of: Self.blob, with: Self.blob.uppercased())), "blob")
        XCTAssertEqual(reason(Self.minimal.replacingOccurrences(of: Self.blob, with: String(Self.blob.dropFirst()))), "blob")
        XCTAssertEqual(reason("[1,2]"), "not an object")
        XCTAssertEqual(reason("null"), "not an object")
        XCTAssertEqual(reason(Self.desc(#","mime":"image/jpeg\n""#)), "mime")
        XCTAssertEqual(reason(Self.desc(#","mime":"jpeg""#)), "mime")
        XCTAssertEqual(reason(Self.desc(#","name":"""#)), "name")
        XCTAssertEqual(reason(Self.desc(#","name":"a\u0007b""#)), "name")
        XCTAssertEqual(reason(Self.desc(#","name":"a\u0085b""#)), "name")
        XCTAssertEqual(reason(Self.desc(#","name":7"#)), "name")
    }

    func testKeyAndNonceMustBeCanonicalBase64url() {
        let key = Self.key
        XCTAssertEqual(reason(Self.minimal.replacingOccurrences(of: key, with: key.dropLast() + "9")), "key")   // 끝 비트가 0 이 아님
        XCTAssertEqual(reason(Self.minimal.replacingOccurrences(of: key, with: key + "=")), "key")
        XCTAssertEqual(reason(Self.minimal.replacingOccurrences(of: key, with: key.replacingOccurrences(of: "A", with: "+"))), "key")
        XCTAssertEqual(reason(Self.minimal.replacingOccurrences(of: key, with: String(key.dropFirst(4)))), "key")
        XCTAssertEqual(reason(Self.minimal.replacingOccurrences(of: Self.nonceField, with: #""nonce":"\#(Self.nonce)AAAA""#)), "nonce")
        XCTAssertEqual(reason(Self.minimal.replacingOccurrences(of: Self.nonceField, with: #""nonce":"""#)), "nonce")
        XCTAssertNil(FileV2Format.base64urlDecode("A"))
        XCTAssertEqual(FileV2Format.base64urlDecode("_w"), Data([0xFF]))
        XCTAssertEqual(FileV2Format.base64urlEncode(Data([0xFB, 0xFF])), "-_8")
    }

    func testStrictJSON() {
        let m = Self.minimal
        for bad in [
            m + " x", String(m.dropLast()) + ",}", m.replacingOccurrences(of: #""v":2"#, with: "v:2"),
            m.replacingOccurrences(of: #""v":2"#, with: "'v':2"), m.replacingOccurrences(of: #""v":2"#, with: #""v":02"#),
            m.replacingOccurrences(of: #""v":2"#, with: #""v":NaN"#), Self.desc(",\"name\":\"a\tb\""), Self.desc(#","name":"\x""#),
            m + "\n// c", "\u{FEFF}" + m, "", String(repeating: "[", count: 40) + String(repeating: "]", count: 40),
            String(m.dropLast()) + #","size":11}"#,          // 중복 키(웹은 뒤 값 — 닫는 쪽)
            Self.desc(#","name":"a\uD800b""#),               // 짝 없는 서로게이트
        ] {
            XCTAssertEqual(reason(bad), "not json", String(bad.prefix(80)))
        }
    }

    func testByteLevelRejections() throws {
        let big = Self.desc(#","name":"\#(String(repeating: "a", count: 200))""#).padding(toLength: FileV2Format.maxDescriptorBytes + 1, withPad: " ", startingAt: 0)
        XCTAssertEqual(reason(big), "too large")
        XCTAssertThrowsError(try FileV2Format.parseDescriptor(Data([0x7B, 0xC3, 0x28, 0x7D]))) {
            XCTAssertEqual(($0 as? FileV2Format.Rejected)?.reason, "not utf-8")
        }
        let exact = Self.desc("").padding(toLength: FileV2Format.maxDescriptorBytes, withPad: " ", startingAt: 0)
        XCTAssertEqual(try parse(exact).size, 10, "exactly 4096 bytes is allowed")
    }

    func testClientIdShape() {
        XCTAssertTrue(FileV2Format.isClientId(Self.clientId))
        XCTAssertFalse(FileV2Format.isClientId(Self.clientId.uppercased()))
        XCTAssertFalse(FileV2Format.isClientId(Self.clientId + "-x"))
        XCTAssertFalse(FileV2Format.isClientId("file-v1-0f8fad5b-d9cb-469f-a165-70867728950e"))
        XCTAssertTrue(FileV2Format.isFileV2Message(clientId: "file-v2-not-a-uuid"), "prefix alone keeps it out of .text")
        XCTAssertFalse(AttachmentFormat.isAttachment(clientId: Self.clientId))
    }

    #if os(Linux) || !canImport(CryptoKit)
    /// Linux: `open` 은 있어야 하고(앱 소스가 함께 컴파일된다 — linux-smoke), 열지 않고 `.unsupported` 를 던진다.
    func testOpenIsUnsupportedWithoutCryptoKit() throws {
        let d = try parse(Self.minimal)
        XCTAssertThrowsError(try FileV2Format.open(Data(count: d.size + FileV2Format.gcmTagBytes), d)) {
            XCTAssertEqual($0 as? FileV2Format.OpenError, .unsupported)
        }
    }
    #endif

    func testKindIsFile() {
        XCTAssertEqual(MessageRecord.Kind(rawValue: "file-v2"), .fileV2, "same stored word as web/Android history")
        XCTAssertTrue(MessageRecord.Kind.fileV2.isFile)
        XCTAssertTrue(MessageRecord.Kind.attachment.isFile)
        XCTAssertFalse(MessageRecord.Kind.text.isFile)
        XCTAssertFalse(MessageRecord.Kind.undecryptable.isFile)
    }
}
