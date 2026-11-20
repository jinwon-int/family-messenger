// 첨부(≤256 KiB) 와이어 규칙 — relay-app `relay-attachments.js`·RELAY-APP.md §첨부와 **같은 형식**(#271 §9-4, 작업지시서 4절 #9).
//
//   첨부 1개 = MLS application 메시지 1개. 평문은 **원본 파일 바이트 그대로**(봉투·base64·MIME·파일명 없음 — 파사드 262,144 B 한도를 다 쓴다).
//   첨부인지는 릴레이 행의 바깥 `client_id` 가 `file-v1-<uuid(소문자)>` 인지로만 판단한다 — 표시 힌트일 뿐 인증 정보가 아니다.
//   MLS AAD 의 client_id 는 여전히 기기 ID 다(파사드 H1). 웹은 정규식에 안 맞으면 바이트를 UTF-8 텍스트로 풀어 보이므로 접두사·대소문자가 정확해야 한다.
//
// 분리 첨부 file-v2(`file-v2-<uuid>`, 파일은 릴레이 blob 저장소·MLS 에는 설명자만, #499)는 archive/native-mls/FILE-V2.md 가 정본 — 이 파일은 v1 규칙이다.
// file-v2 수신 검증은 `FileV2Format.swift`(같은 디렉터리) — `file-v2-` 메시지는 `.text` 로 두지 않는다.
//
// 수신 쪽 표시 메타(`MessageRecord.body`)는 메타데이터가 없으니 **매직 바이트로 추정한 MIME** 을 넣는다 — NSE 의 「사진」/「파일」 판정이 이 값을 읽는다.
//
// #851: pptx·docx·xlsx 는 ZIP 컨테이너라 앞머리만 보면 전부 `application/zip` 이다 — ZIP 중앙 디렉터리의 **항목 이름만** 읽어 가린다
// (`officeMime`, 압축 해제·XML 파싱 없음). 저장·공유 이름은 보낸 쪽 `name` 힌트(file-v2)를 쓰되(`exportName`), 내용으로 종류를 아는
// 파일은 확장자가 그 내용과 맞아야 한다 — 이름만으로 앱 안 미리보기(QuickLook)의 종류가 바뀌지 않게.
import Foundation

public enum AttachmentFormat {
    /// 파사드 `MAX_ATTACHMENT`(openmls-browser lib.rs)·웹 `MAX_ATTACHMENT` 과 동일 — #364 결정 B: 5 MiB(2026-10-15 이전 256 KiB).
    public static let maxBytes = 5 * 1024 * 1024
    public static let clientIdPrefix = "file-v1-"
    public static let fallbackMime = "application/octet-stream"

    /// `^file-v1-[a-f0-9-]{36}$`
    public static func isAttachment(clientId: String) -> Bool {
        guard clientId.hasPrefix(clientIdPrefix) else { return false }
        let tail = clientId.dropFirst(clientIdPrefix.count)
        guard tail.count == 36 else { return false }
        return tail.unicodeScalars.allSatisfy { ("a"..."f").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// 새 첨부용 릴레이 client_id(UUID 소문자 — 대문자면 웹 정규식에 걸리지 않는다).
    public static func newClientId(uuid: UUID = UUID()) -> String {
        clientIdPrefix + uuid.uuidString.lowercased()
    }

    /// 매직 바이트로 MIME 추정. 모르면 `application/octet-stream`.
    public static func sniffMime(_ data: Data) -> String {
        let head = [UInt8](data.prefix(16))
        func starts(_ bytes: [UInt8]) -> Bool { head.count >= bytes.count && Array(head[0..<bytes.count]) == bytes }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts([0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if head.count >= 12, Array(head[0..<4]) == [0x52, 0x49, 0x46, 0x46], Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if head.count >= 12, Array(head[4..<8]) == [0x66, 0x74, 0x79, 0x70] {   // "ftyp" — ISO BMFF
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) { return "image/heic" }
            if ["avif", "avis"].contains(brand) { return "image/avif" }
            return "video/mp4"
        }
        if starts([0x25, 0x50, 0x44, 0x46, 0x2D]) { return "application/pdf" }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return officeMime(data) ?? zipMime }
        return fallbackMime
    }

    public static let zipMime = "application/zip"
    public static let pptxMime = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    public static let docxMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    public static let xlsxMime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    /// ZIP 주석 최대(65,535) + 끝 레코드(22) — 끝 레코드는 이 안에 있다.
    static let zipTailBytes = 22 + 65_535
    /// 중앙 디렉터리는 앞에서부터 이만큼만, 항목은 이만큼만 본다(받은 파일은 믿지 않는다 — 읽는 양을 묶는다).
    static let zipDirectoryBytes = 1024 * 1024
    static let zipDirectoryEntries = 4096

    /// #851: ZIP 안이 OOXML(PowerPoint·Word·Excel)이면 그 MIME, 아니면 nil(그냥 ZIP — hwpx·epub·jar 등도 여기).
    /// 중앙 디렉터리의 항목 **이름**만 읽는다: `[Content_Types].xml` 이 있고 최상위 폴더 `ppt/`·`word/`·`xl/` 중 **하나만** 있을 때.
    /// 매크로 문서(`vbaProject.bin`)는 확장자가 달라(pptm 등) 가리지 않는다. 형식이 어긋나면(잘림·ZIP64·범위 밖 오프셋) nil.
    static func officeMime(_ data: Data) -> String? {
        let total = data.count
        guard total >= 22 else { return nil }
        let tail = [UInt8](data.suffix(min(total, zipTailBytes)))
        func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }
        // 끝 레코드(PK\x05\x06)를 뒤에서부터 찾는다 — 주석 길이가 남은 바이트와 맞는 첫 번째.
        var end = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06, i + 22 + u16(tail, i + 20) == tail.count {
                end = i
                break
            }
            i -= 1
        }
        guard end >= 0 else { return nil }
        let size = u32(tail, end + 12), offset = u32(tail, end + 16)
        guard size > 0, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF, offset <= total, size <= total - offset else { return nil }
        let from = data.index(data.startIndex, offsetBy: offset)
        let dir = [UInt8](data[from..<data.index(from, offsetBy: min(size, zipDirectoryBytes))])
        var contentTypes = false, macros = false
        var kinds = Set<String>()
        var p = 0, seen = 0
        while seen < zipDirectoryEntries, p + 46 <= dir.count,
              dir[p] == 0x50, dir[p + 1] == 0x4B, dir[p + 2] == 0x01, dir[p + 3] == 0x02 {
            let nameLength = u16(dir, p + 28), nameStart = p + 46
            guard nameStart + nameLength <= dir.count else { break }
            let name = String(decoding: dir[nameStart..<nameStart + nameLength], as: UTF8.self)
            if name == "[Content_Types].xml" { contentTypes = true }
            if name.hasSuffix("/vbaProject.bin") { macros = true }
            if name.hasPrefix("ppt/") { kinds.insert(pptxMime) }
            if name.hasPrefix("word/") { kinds.insert(docxMime) }
            if name.hasPrefix("xl/") { kinds.insert(xlsxMime) }
            p = nameStart + nameLength + u16(dir, p + 30) + u16(dir, p + 32)
            seen += 1
        }
        guard contentTypes, !macros, kinds.count == 1 else { return nil }
        return kinds.first
    }

    public static func isImage(mime: String) -> Bool { mime.hasPrefix("image/") }

    /// 받은 바이트를 `sniffMime` 으로 판별한 결과가 PDF(`%PDF-`)인가 — 보낸 쪽 힌트가 아니라 내용 판별 결과만 넘긴다.
    /// 앱은 이것일 때만 첨부를 QuickLook 으로 연다(오너 요청 2026-11-06).
    public static func isPDF(mime: String) -> Bool { mime == "application/pdf" }

    /// 저장·공유용 확장자(웹은 `attachment-<seq>.bin`; 여기서는 MIME 을 알면 그 확장자).
    public static func fileExtension(mime: String) -> String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/avif": return "avif"
        case "video/mp4": return "mp4"
        case "application/pdf": return "pdf"
        case zipMime: return "zip"
        case pptxMime: return "pptx"
        case docxMime: return "docx"
        case xlsxMime: return "xlsx"
        default: return "bin"
        }
    }

    /// 내용으로 정한 MIME 에 맞는 확장자들(소문자, 첫째 = `fileExtension`). 빈 배열 = 내용만으로는 종류를 모른다(그냥 ZIP·알 수 없는 바이트).
    /// `video/mp4` 는 `ftyp` 상자 전체(mov·m4a·3gp 포함)라 그 확장자들도 맞는 것으로 본다. OOXML 은 같은 계열(서식·쇼)까지.
    public static func matchingExtensions(mime: String) -> [String] {
        switch mime {
        case "image/jpeg": return ["jpg", "jpeg"]
        case "image/png": return ["png"]
        case "image/gif": return ["gif"]
        case "image/webp": return ["webp"]
        case "image/heic": return ["heic", "heif"]
        case "image/avif": return ["avif"]
        case "video/mp4": return ["mp4", "m4v", "mov", "m4a", "3gp"]
        case "application/pdf": return ["pdf"]
        case pptxMime: return ["pptx", "ppsx", "potx"]
        case docxMime: return ["docx", "dotx"]
        case xlsxMime: return ["xlsx", "xltx"]
        default: return []
        }
    }

    /// 저장 이름의 UTF-8 상한 — 파일 시스템(APFS) 이름 한도 255 B 아래로, 방·seq 폴더 경로 여유를 둔다.
    static let maxExportNameBytes = 200

    /// 보낸 쪽 파일 이름 힌트(file-v2 `name`)를 저장·표시 이름으로 줄인다 — 웹 `file-v2.js safeFileName`·안드로이드
    /// `AttachmentFiles.safeName` 과 같은 규칙: 마지막 경로 조각 · 앞뒤 공백 제거 · 제어 문자·양방향 제어 문자(확장자 위장) 없음 ·
    /// 점으로 시작하지 않음 · 255 코드 포인트 이하. 맞지 않으면 nil(이름 없이 다룬다). 긴 이름은 확장자를 두고 줄인다.
    public static func safeFileName(_ hint: String?) -> String? {
        guard let hint else { return nil }
        let forbidden: (Unicode.Scalar) -> Bool = { u in
            let v = u.value
            return v <= 0x1F || (0x7F...0x9F).contains(v) || v == 0x061C || v == 0x200E || v == 0x200F
                || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
        }
        guard !hint.unicodeScalars.contains(where: forbidden) else { return nil }
        let last = hint.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "\\" }.last.map { String($0) } ?? ""
        let base = last.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !base.hasPrefix("."), base.unicodeScalars.count <= 255 else { return nil }
        return fitted(base)
    }

    /// 이름의 마지막 `.확장자`(소문자, 점 없이). 점이 없거나 맨 앞·맨 끝이면 빈 문자열.
    static func nameExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// `maxExportNameBytes` 를 넘는 이름을 확장자(16 B 이하일 때)를 남기고 앞에서부터 자른다.
    static func fitted(_ name: String) -> String {
        guard name.utf8.count > maxExportNameBytes else { return name }
        var suffix = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let tail = String(name[dot...])
            if tail.utf8.count <= 17 { suffix = tail }
        }
        var stem = String(name.dropLast(suffix.count))
        while !stem.isEmpty, stem.utf8.count + suffix.utf8.count > maxExportNameBytes { stem.removeLast() }
        return stem.isEmpty ? name : stem + suffix
    }

    /// 저장·공유 파일 이름(#851). `mime` 은 **내용으로 정한** MIME(`sniffMime`)만 넘긴다 — 보낸 쪽 힌트가 아니다.
    ///   · 쓸 수 있는 이름 힌트가 없으면 종전대로 `attachment-<seq>.<확장자>`.
    ///   · 내용으로 종류를 아는 파일은 이름의 확장자가 그 종류와 맞을 때만 그대로 쓰고, 다르면 내용의 확장자를 **덧붙인다**
    ///     (`계약서.html` + PDF 내용 → `계약서.html.pdf`) — 이름으로 QuickLook·다른 앱이 여는 방식을 바꾸지 못한다.
    ///   · 내용으로 종류를 모르면(그냥 ZIP·알 수 없는 바이트) 보낸 이름 그대로(hwp·hwpx·txt 등이 제 이름으로 저장된다).
    public static func exportName(seq: Int64, mime: String, nameHint: String?) -> String {
        guard let name = safeFileName(nameHint) else { return "attachment-\(seq).\(fileExtension(mime: mime))" }
        let matching = matchingExtensions(mime: mime)
        guard let primary = matching.first, !matching.contains(nameExtension(name)) else { return name }
        return fitted(name + "." + primary)
    }

    /// 말풍선의 종류 표시(이름 힌트가 없을 때). OOXML 의 긴 MIME 대신 짧은 이름, 그 밖은 MIME 그대로.
    public static func typeLabel(mime: String) -> String {
        switch mime {
        case pptxMime: return "PowerPoint"
        case docxMime: return "Word"
        case xlsxMime: return "Excel"
        case zipMime: return "ZIP"
        default: return mime
        }
    }
}
