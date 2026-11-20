// 첨부 송수신(AttachmentFormat + RoomSyncEngine.send(attachment:)) — 가짜 엔진·메모리 릴레이(SyncFakes.swift). 와이어 규칙은 relay-app 과 동일해야 한다.
import XCTest
@testable import FamilyMLSCore

final class SyncAttachmentTests: XCTestCase {
    let alice = "alice-pc"

    private func joinedHarness() throws -> SyncHarness {
        let h = try SyncHarness()
        try h.store.seed(room: h.room, .joined([alice, h.me].sorted(), epoch: 1, pending: nil))
        h.relay.epoch = 1
        h.relay.members = [alice, h.me]
        return h
    }

    /// 가짜 암호문(바이트 평문) — `SyncHarness.ciphertext(from:clientId:text:)` 의 Data 판.
    private func ciphertext(from sender: DeviceID, bytes: Data) -> Data {
        var plain = bytes; plain.append(0)
        return FakeMlsEngine.ciphertextMagic + Framing.encryptInput(room: sender, clientId: sender, plaintext: plain)
    }

    static let jpegHead = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00])

    // MARK: 형식

    func testClientIdRuleMatchesRelayApp() {
        let id = AttachmentFormat.newClientId(uuid: UUID(uuidString: "0F3C2A9B-1D2E-4F5A-8B6C-7D8E9FA0B1C2")!)
        XCTAssertEqual(id, "file-v1-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2", "lowercase uuid — the web regex is [a-f0-9-]")
        XCTAssertTrue(AttachmentFormat.isAttachment(clientId: id))
        XCTAssertFalse(AttachmentFormat.isAttachment(clientId: "file-v1-0F3C2A9B-1D2E-4F5A-8B6C-7D8E9FA0B1C2"), "uppercase is text to the web")
        XCTAssertFalse(AttachmentFormat.isAttachment(clientId: "file-v1-abc"))
        XCTAssertFalse(AttachmentFormat.isAttachment(clientId: "me-iphone-aaaaaa-c1"))
        XCTAssertFalse(AttachmentFormat.isAttachment(clientId: ""))
        XCTAssertEqual(id.count, 44, "fits the relay's 64-char client_id limit")
    }

    func testMimeSniffing() {
        XCTAssertEqual(AttachmentFormat.sniffMime(Self.jpegHead), "image/jpeg")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1])), "image/png")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data("GIF89a".utf8)), "image/gif")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypheic".utf8) + Data(count: 4)), "image/heic")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypisom".utf8) + Data(count: 4)), "video/mp4")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data("%PDF-1.7".utf8)), "application/pdf")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data("hello".utf8)), AttachmentFormat.fallbackMime)
        XCTAssertEqual(AttachmentFormat.sniffMime(Data()), AttachmentFormat.fallbackMime)
        XCTAssertTrue(AttachmentFormat.isImage(mime: "image/heic"))
        XCTAssertEqual(AttachmentFormat.fileExtension(mime: "image/jpeg"), "jpg")
        XCTAssertEqual(AttachmentFormat.fileExtension(mime: "x/y"), "bin")
    }

    /// 오너 요청 2026-11-06: 앱은 내용 판별이 PDF 일 때만 QuickLook 으로 연다 — `.pdf` 이름·힌트만으로는 PDF 가 아니다.
    func testPDFIsDecidedByContent() {
        XCTAssertTrue(AttachmentFormat.isPDF(mime: AttachmentFormat.sniffMime(Data("%PDF-1.4\n%âãÏÓ".utf8))))
        XCTAssertEqual(AttachmentFormat.fileExtension(mime: AttachmentFormat.sniffMime(Data("%PDF-1.7".utf8))), "pdf")
        for notPDF in [Data("<html>%PDF-1.7".utf8), Data("%PDF".utf8), Data(" %PDF-1.7".utf8), Self.jpegHead, Data()] {
            XCTAssertFalse(AttachmentFormat.isPDF(mime: AttachmentFormat.sniffMime(notPDF)), "\(Array(notPDF.prefix(8)))")
        }
        XCTAssertFalse(AttachmentFormat.isPDF(mime: "application/x-pdf"))
        XCTAssertFalse(AttachmentFormat.isPDF(mime: AttachmentFormat.fallbackMime))
    }

    // MARK: #851 — OOXML 은 ZIP 중앙 디렉터리의 항목 이름으로 가린다 · 저장 이름은 보낸 쪽 이름 힌트

    /// 무압축 ZIP 을 만든다 — 항목마다 로컬 헤더 + 내용 1 B, 뒤에 중앙 디렉터리와 끝 레코드(CRC 는 0 — 판별은 이름만 읽는다).
    static func zip(_ names: [String], comment: String = "") -> Data {
        var out = [UInt8](), directory = [UInt8]()
        func le16(_ v: Int, into b: inout [UInt8]) { b.append(UInt8(v & 0xFF)); b.append(UInt8((v >> 8) & 0xFF)) }
        func le32(_ v: Int, into b: inout [UInt8]) { le16(v & 0xFFFF, into: &b); le16((v >> 16) & 0xFFFF, into: &b) }
        for name in names {
            let bytes = Array(name.utf8)
            let offset = out.count
            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            for v in [20, 0, 0, 0, 0] { le16(v, into: &out) }           // version · flags · method · time · date
            for v in [0, 1, 1] { le32(v, into: &out) }                  // crc · compressed · uncompressed
            le16(bytes.count, into: &out); le16(0, into: &out)          // name · extra
            out.append(contentsOf: bytes)
            out.append(0x78)
            directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            for v in [20, 20, 0, 0, 0, 0] { le16(v, into: &directory) } // made by · needed · flags · method · time · date
            for v in [0, 1, 1] { le32(v, into: &directory) }
            for v in [bytes.count, 0, 0, 0, 0] { le16(v, into: &directory) }   // name · extra · comment · disk · internal attrs
            le32(0, into: &directory); le32(offset, into: &directory)   // external attrs · local header offset
            directory.append(contentsOf: bytes)
        }
        let start = out.count
        out.append(contentsOf: directory)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        for v in [0, 0, names.count, names.count] { le16(v, into: &out) }
        le32(directory.count, into: &out); le32(start, into: &out)
        le16(comment.utf8.count, into: &out)
        out.append(contentsOf: Array(comment.utf8))
        return Data(out)
    }

    static let pptxNames = ["[Content_Types].xml", "_rels/.rels", "ppt/presentation.xml", "ppt/slides/slide1.xml", "docProps/app.xml"]

    func testOfficeDocumentsAreToldApartFromAPlainZip() {
        let pptx = Self.zip(Self.pptxNames)
        XCTAssertEqual(AttachmentFormat.sniffMime(pptx), AttachmentFormat.pptxMime)
        XCTAssertEqual(AttachmentFormat.sniffMime(Self.zip(["[Content_Types].xml", "word/document.xml", "word/embeddings/sheet1.xlsx"])),
                       AttachmentFormat.docxMime, "an embedded workbook lives under word/ — still a Word document")
        XCTAssertEqual(AttachmentFormat.sniffMime(Self.zip(["xl/workbook.xml", "xl/worksheets/sheet1.xml", "[Content_Types].xml"])),
                       AttachmentFormat.xlsxMime, "entry order does not matter")
        XCTAssertEqual(AttachmentFormat.sniffMime(Self.zip(Self.pptxNames, comment: "made by a test")), AttachmentFormat.pptxMime)
        XCTAssertEqual(AttachmentFormat.fileExtension(mime: AttachmentFormat.pptxMime), "pptx")
        XCTAssertEqual(AttachmentFormat.fileExtension(mime: AttachmentFormat.docxMime), "docx")
        XCTAssertEqual(AttachmentFormat.fileExtension(mime: AttachmentFormat.xlsxMime), "xlsx")
        // Data 조각(startIndex ≠ 0)도 같은 결과 — 오프셋은 조각의 시작 기준이다.
        let padded = Data([0, 0, 0]) + pptx
        XCTAssertEqual(AttachmentFormat.sniffMime(padded.dropFirst(3)), AttachmentFormat.pptxMime)
        // 그냥 ZIP 으로 남는 것들
        for names in [["a.txt", "b/c.txt"],                                             // 보통 ZIP
                      ["mimetype", "Contents/section0.xml", "META-INF/manifest.xml"],   // hwpx
                      ["ppt/presentation.xml"],                                         // [Content_Types].xml 없음
                      ["[Content_Types].xml", "ppt/presentation.xml", "word/document.xml"],   // 둘 이상
                      ["[Content_Types].xml", "ppt/presentation.xml", "ppt/vbaProject.bin"],   // 매크로(pptm)
                      ["[Content_Types].xml"]] {
            XCTAssertEqual(AttachmentFormat.sniffMime(Self.zip(names)), AttachmentFormat.zipMime, "\(names)")
        }
        XCTAssertEqual(AttachmentFormat.fileExtension(mime: AttachmentFormat.zipMime), "zip")
        // 보낼 때 설명자 mime 힌트로 실을 수 있는 모양이다(FILE-V2.md §1: 토큰 ≤ 64, 전체 ≤ 100).
        for mime in [AttachmentFormat.pptxMime, AttachmentFormat.docxMime, AttachmentFormat.xlsxMime] {
            XCTAssertLessThanOrEqual(mime.utf8.count, 100)
            XCTAssertLessThanOrEqual(mime.split(separator: "/").last?.utf8.count ?? 99, 64)
        }
    }

    /// 받은 바이트는 믿지 않는다 — 잘리거나 어긋난 ZIP 은 그냥 ZIP 으로 남고, 범위 밖을 읽지 않는다.
    func testMalformedZipStaysAZipAndNeverReadsOutOfRange() {
        let pptx = Self.zip(Self.pptxNames)
        for cut in [4, 21, 22, 30, 46, pptx.count / 2, pptx.count - 23, pptx.count - 1] {
            XCTAssertEqual(AttachmentFormat.sniffMime(pptx.prefix(cut)), AttachmentFormat.zipMime, "cut at \(cut)")
        }
        let end = pptx.count - 22
        func patched(_ at: Int, _ bytes: [UInt8]) -> Data {
            var copy = [UInt8](pptx)
            for (i, b) in bytes.enumerated() { copy[at + i] = b }
            return Data(copy)
        }
        let directoryStart = Int(pptx[end + 16]) | Int(pptx[end + 17]) << 8
        XCTAssertEqual(AttachmentFormat.sniffMime(patched(end + 16, [0xFF, 0xFF, 0xFF, 0x7F])), AttachmentFormat.zipMime, "directory offset past the end")
        XCTAssertEqual(AttachmentFormat.sniffMime(patched(end + 16, [0xFF, 0xFF, 0xFF, 0xFF])), AttachmentFormat.zipMime, "ZIP64 marker")
        XCTAssertEqual(AttachmentFormat.sniffMime(patched(end + 12, [0xFF, 0xFF, 0xFF, 0x7F])), AttachmentFormat.zipMime, "directory size past the end")
        XCTAssertEqual(AttachmentFormat.sniffMime(patched(end + 12, [0, 0, 0, 0])), AttachmentFormat.zipMime, "empty directory")
        XCTAssertEqual(AttachmentFormat.sniffMime(patched(directoryStart + 28, [0xFF, 0xFF])), AttachmentFormat.zipMime, "first entry name runs past the directory")
        XCTAssertEqual(AttachmentFormat.sniffMime(patched(directoryStart, [0, 0, 0, 0])), AttachmentFormat.zipMime, "directory does not start with an entry")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0x50, count: 70_000)), AttachmentFormat.zipMime)
        XCTAssertEqual(AttachmentFormat.sniffMime(Data([0x50, 0x4B, 0x03, 0x04])), AttachmentFormat.zipMime)
    }

    func testSafeFileNameFollowsTheWebAndAndroidRule() {
        XCTAssertEqual(AttachmentFormat.safeFileName("집행사건 교육자료 (1).pptx"), "집행사건 교육자료 (1).pptx")
        XCTAssertEqual(AttachmentFormat.safeFileName("C:\\Users\\me\\a.pptx"), "a.pptx")
        XCTAssertEqual(AttachmentFormat.safeFileName("/tmp/x/b.docx"), "b.docx")
        XCTAssertEqual(AttachmentFormat.safeFileName("  a.txt  "), "a.txt")
        for bad in [nil, "", "   ", ".env", "..", "a/", "dir\\", "a\u{202E}xtpp.exe", "a\u{2066}b.txt", "a\nb.txt", "a\u{85}b.txt",
                    String(repeating: "a", count: 256)] as [String?] {
            XCTAssertNil(AttachmentFormat.safeFileName(bad), "\(bad ?? "nil")")
        }
        // 긴 이름(한글 240자 = 720 B)은 확장자를 두고 파일 시스템 한도 안으로 줄인다.
        let long = AttachmentFormat.safeFileName(String(repeating: "가", count: 240) + ".pptx")
        XCTAssertEqual(long?.hasSuffix(".pptx"), true)
        XCTAssertLessThanOrEqual(long?.utf8.count ?? 999, AttachmentFormat.maxExportNameBytes)
        XCTAssertGreaterThan(long?.utf8.count ?? 0, AttachmentFormat.maxExportNameBytes - 4)
    }

    /// 종류는 내용으로만 정한다: 이름 힌트는 내용과 맞을 때만 그대로, 어긋나면 내용의 확장자가 붙는다.
    func testExportNameKeepsTheSenderNameButNeverLetsItChangeTheKind() {
        let pdf = "application/pdf"
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: AttachmentFormat.pptxMime, nameHint: nil), "attachment-7.pptx")
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: AttachmentFormat.zipMime, nameHint: nil), "attachment-7.zip")
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: AttachmentFormat.pptxMime, nameHint: "교육자료 (1).pptx"), "교육자료 (1).pptx")
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: AttachmentFormat.pptxMime, nameHint: "쇼.PPSX"), "쇼.PPSX")
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: "image/jpeg", nameHint: "IMG_0001.JPEG"), "IMG_0001.JPEG")
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: "video/mp4", nameHint: "clip.mov"), "clip.mov")
        // 내용으로 종류를 모르면 보낸 이름 그대로
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: AttachmentFormat.zipMime, nameHint: "문서.hwpx"), "문서.hwpx")
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: AttachmentFormat.fallbackMime, nameHint: "메모.txt"), "메모.txt")
        // 내용과 어긋나는 확장자·확장자 없음 → 내용의 확장자를 덧붙인다
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: pdf, nameHint: "계약서.html"), "계약서.html.pdf")
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: "image/png", nameHint: "a.jpg"), "a.jpg.png")
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: pdf, nameHint: "이름없음"), "이름없음.pdf")
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: AttachmentFormat.docxMime, nameHint: "a.pdf"), "a.pdf.docx")
        // 쓸 수 없는 힌트 → 종전 이름
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: pdf, nameHint: ".hidden"), "attachment-7.pdf")
        XCTAssertEqual(AttachmentFormat.exportName(seq: 7, mime: pdf, nameHint: "a\u{202E}fdp.exe"), "attachment-7.pdf")
        XCTAssertEqual(AttachmentFormat.typeLabel(mime: AttachmentFormat.pptxMime), "PowerPoint")
        XCTAssertEqual(AttachmentFormat.typeLabel(mime: pdf), pdf)
    }

    // MARK: 송신

    func testSendAttachmentUsesFileV1ClientIdAndRawBytes() async throws {
        let h = try joinedHarness()
        let bytes = Self.jpegHead + Data(repeating: 0xAB, count: 1000)
        let outcome = try await h.sync.send(attachment: bytes)
        guard case .sent(let clientId, _, false) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(AttachmentFormat.isAttachment(clientId: clientId), clientId)
        XCTAssertEqual(h.relay.posts[0].clientId, clientId)
        XCTAssertEqual(h.relay.posts[0].kind, .application)
        // 가짜 암호문 = magic ‖ sender ‖ AAD client_id(기기 ID 그대로) ‖ 평문 ‖ generation
        let framed = Data(h.relay.posts[0].bytes.dropFirst(FakeMlsEngine.ciphertextMagic.count))
        var at = 0
        XCTAssertEqual(try Framing.readString(framed, &at), h.me)
        XCTAssertEqual(try Framing.readString(framed, &at), h.me, "AAD client_id stays the device id — the file-v1 id is relay-only")
        XCTAssertEqual(framed.subdata(in: at..<(framed.count - 1)), bytes, "raw file bytes, no envelope")
        XCTAssertEqual(try h.outbox.pending(room: h.room), [])
    }

    func testSendAttachmentRejectsOversizeBeforeEncrypting() async throws {
        let h = try joinedHarness()
        let big = Data(count: AttachmentFormat.maxBytes + 1)
        do { _ = try await h.sync.send(attachment: big); XCTFail("must refuse") }
        catch { XCTAssertEqual(error as? SyncError, .attachmentTooLarge(AttachmentFormat.maxBytes + 1)) }
        XCTAssertEqual(h.factory.log.count(.encrypt), 0, "no ratchet use for a refused attachment")
        XCTAssertEqual(h.relay.posts.count, 0)
        _ = try await h.sync.send(attachment: Data(count: AttachmentFormat.maxBytes))   // 정확히 한도는 허용
        XCTAssertEqual(h.relay.posts.count, 1)
    }

    func testCasRetryReencryptsWithAFreshFileV1Id() async throws {
        let h = try joinedHarness()
        h.relay.postErrors = [RelayError.cas(epoch: 2, revision: 1)]
        let outcome = try await h.sync.send(attachment: Self.jpegHead)
        guard case .sent(let second, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(h.relay.posts.count, 2)
        let first = h.relay.posts[0].clientId
        XCTAssertTrue(AttachmentFormat.isAttachment(clientId: first))
        XCTAssertTrue(AttachmentFormat.isAttachment(clientId: second))
        XCTAssertNotEqual(first, second, "a re-encryption is a new delivery — new relay id")
        XCTAssertEqual(try h.outbox.pending(room: h.room), [])
    }

    func testTextSendStillUsesTheDeviceClientId() async throws {
        let h = try joinedHarness()
        guard case .sent(let clientId, _, _) = try await h.sync.send(text: "hi") else { return XCTFail() }
        XCTAssertTrue(clientId.hasPrefix(h.me))
        XCTAssertFalse(AttachmentFormat.isAttachment(clientId: clientId))
    }

    // MARK: NSE 보호 — 큰 application 은 커서 앞에서 멈춘다(#364)

    func testApplicationOverTheProcessCapIsDeferredAndLeftForAnUncappedCaller() async throws {
        let h = try joinedHarness()
        let small = h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: Data("hi".utf8)))
        let bigBytes = ciphertext(from: alice, bytes: Data(repeating: 0xAA, count: 4_000))
        let big = h.relay.inject(device: alice, kind: .application, bytes: bigBytes, clientId: AttachmentFormat.newClientId())
        let after = h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: Data("later".utf8)))

        h.configuration.maxApplicationBytes = 1_000     // NSE 와 같은 캡
        let capped = try h.restart()
        let passes = try await capped.syncAll()
        XCTAssertEqual(passes.count, 1, "syncAll stops at the deferral")
        XCTAssertEqual(passes[0].deferredSeq, big)
        XCTAssertEqual(passes[0].inserted, [small], "everything before the big event is processed")
        XCTAssertEqual(passes[0].cursor, small, "the cursor stays right before the deferred event")
        XCTAssertFalse(passes[0].hasMore)
        XCTAssertEqual(try h.cursors.cursor(room: h.room), small)
        XCTAssertEqual(try h.messages.messages(room: h.room, after: 0, limit: 10).map(\.seq), [small])
        // 같은 캡으로 다시 돌려도 같은 자리에서 멈춘다(무한 루프·중복 없음).
        let again = try await capped.syncOnce()
        XCTAssertEqual(again.deferredSeq, big)
        XCTAssertEqual(again.inserted, [])

        h.configuration.maxApplicationBytes = nil       // 앱: 제한 없음 → 이어서 처리
        let app = try h.restart()
        let rest = try await app.syncAll()
        XCTAssertEqual(rest.flatMap(\.inserted), [big, after])
        XCTAssertEqual(try h.cursors.cursor(room: h.room), after)
        let stored = try h.messages.messages(room: h.room, after: 0, limit: 10)
        XCTAssertEqual(stored.map(\.seq), [small, big, after])
        XCTAssertEqual(stored[1].kind, .attachment)
    }

    // MARK: 수신

    func testIncomingFileV1EventIsStoredAsAttachmentWithSniffedMime() async throws {
        let h = try joinedHarness()
        let bytes = Self.jpegHead + Data(repeating: 1, count: 300)
        let seq = h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: bytes),
                                 clientId: AttachmentFormat.newClientId())
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.inserted, [seq])
        let stored = try XCTUnwrap(h.messages.messages(room: h.room, after: 0, limit: 10).first)
        XCTAssertEqual(stored.kind, .attachment)
        XCTAssertEqual(stored.body, "image/jpeg", "display meta = sniffed MIME (NSE shows 「사진」)")
        XCTAssertEqual(stored.attachment, bytes)
        XCTAssertEqual(stored.senderDevice, alice)
    }

    func testIncomingNonMatchingClientIdStaysText() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: Data("hello".utf8)), clientId: "File-V1-not-really")
        _ = try await h.sync.syncOnce()
        let stored = try XCTUnwrap(h.messages.messages(room: h.room, after: 0, limit: 10).first)
        XCTAssertEqual(stored.kind, .text)
        XCTAssertEqual(stored.body, "hello")
        XCTAssertNil(stored.attachment)
    }

    func testIncomingAttachmentWithUnknownBytesIsOctetStream() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: Data([0x00, 0x01, 0x02])),
                       clientId: AttachmentFormat.newClientId())
        _ = try await h.sync.syncOnce()
        let stored = try XCTUnwrap(h.messages.messages(room: h.room, after: 0, limit: 10).first)
        XCTAssertEqual(stored.kind, .attachment)
        XCTAssertEqual(stored.body, AttachmentFormat.fallbackMime)
        XCTAssertEqual(stored.attachment, Data([0x00, 0x01, 0x02]))
    }

    // MARK: 송신 — file-v2(#499 3단계)

    #if os(Linux) || !canImport(CryptoKit)
    /// Linux(AES 없음): 업로드·암호화(ratchet) 전에 멈춘다 — 설명자 없는 게시나 반쯤 보낸 상태가 생기지 않는다.
    func testFileV2SendStopsBeforeUploadWithoutCryptoKit() async throws {
        let h = try joinedHarness()
        do { _ = try await h.sync.send(fileV2: Self.jpegHead); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? FileV2Format.OpenError, .unsupported) }
        XCTAssertEqual(h.relay.posts.count, 0)
        XCTAssertEqual(h.factory.log.count(.encrypt), 0)
    }
    #endif

    func testFileV2SendRefusesOversizeBeforeAnything() async throws {
        let h = try joinedHarness()
        do { _ = try await h.sync.send(fileV2: Data()); XCTFail("empty") }
        catch { XCTAssertEqual(error as? SyncError, .attachmentTooLarge(0)) }
        XCTAssertEqual(h.relay.posts.count, 0)
        XCTAssertEqual(h.factory.log.count(.encrypt), 0)
    }

    // MARK: 수신 — file-v2(#499): 설명자(파일 키)는 어떤 경우에도 .text 로 저장되지 않는다

    func testIncomingFileV2IsStoredAsDescriptorNeverText() async throws {
        let h = try joinedHarness()
        let descriptor = Data(FileV2FormatTests.desc(#","mime":"image/jpeg","name":"사진.jpg""#).utf8)
        let seq = h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: descriptor),
                                 clientId: FileV2FormatTests.clientId)
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.inserted, [seq])
        let stored = try XCTUnwrap(h.messages.messages(room: h.room, after: 0, limit: 10).first)
        XCTAssertEqual(stored.kind, .fileV2)
        XCTAssertEqual(stored.body, "image/jpeg", "display hint only — never the descriptor JSON")
        XCTAssertFalse(stored.body.contains(FileV2FormatTests.key))
        XCTAssertEqual(stored.attachment, descriptor, "history keeps the descriptor only (FILE-V2.md §4-2)")
        XCTAssertEqual(stored.clientId, FileV2FormatTests.clientId)
        XCTAssertEqual(stored.senderDevice, alice)
    }

    func testIncomingFileV2WithoutMimeHasEmptyBody() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: Data(FileV2FormatTests.minimal.utf8)),
                       clientId: FileV2FormatTests.clientId)
        _ = try await h.sync.syncOnce()
        let stored = try XCTUnwrap(h.messages.messages(room: h.room, after: 0, limit: 10).first)
        XCTAssertEqual(stored.kind, .fileV2)
        XCTAssertEqual(stored.body, "")
    }

    func testIncomingBadFileV2IsUndecryptableAndDropsThePlaintext() async throws {
        let h = try joinedHarness()
        let cases: [(String, String)] = [
            (FileV2FormatTests.clientId, FileV2FormatTests.minimal.replacingOccurrences(of: #""v":2"#, with: #""v":3"#)),
            (FileV2FormatTests.clientId, "hello \(FileV2FormatTests.key)"),
            ("file-v2-not-a-uuid", FileV2FormatTests.minimal),   // 접두는 맞지만 정규형이 아님 — 글로 열지 않는다
        ]
        var seqs: [Int64] = []
        for (clientId, text) in cases {
            seqs.append(h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: Data(text.utf8)), clientId: clientId))
        }
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.inserted, seqs, "decryption succeeded — the pass still advances (ack)")
        let stored = try h.messages.messages(room: h.room, after: 0, limit: 10)
        XCTAssertEqual(stored.map(\.kind), [.undecryptable, .undecryptable, .undecryptable])
        for record in stored {
            XCTAssertEqual(record.body, "file_v2_descriptor")
            XCTAssertNil(record.attachment)
            XCTAssertFalse(record.body.contains(FileV2FormatTests.key))
        }
    }
}
