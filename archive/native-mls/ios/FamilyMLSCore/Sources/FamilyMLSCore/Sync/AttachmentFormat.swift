// 첨부(≤256 KiB) 와이어 규칙 — relay-app `relay-attachments.js`·RELAY-APP.md §첨부와 **같은 형식**(#271 §9-4, 작업지시서 4절 #9).
//
//   첨부 1개 = MLS application 메시지 1개. 평문은 **원본 파일 바이트 그대로**(봉투·base64·MIME·파일명 없음 — 파사드 262,144 B 한도를 다 쓴다).
//   첨부인지는 릴레이 행의 바깥 `client_id` 가 `file-v1-<uuid(소문자)>` 인지로만 판단한다 — 표시 힌트일 뿐 인증 정보가 아니다.
//   MLS AAD 의 client_id 는 여전히 기기 ID 다(파사드 H1). 웹은 정규식에 안 맞으면 바이트를 UTF-8 텍스트로 풀어 보이므로 접두사·대소문자가 정확해야 한다.
//
// 수신 쪽 표시 메타(`MessageRecord.body`)는 메타데이터가 없으니 **매직 바이트로 추정한 MIME** 을 넣는다 — NSE 의 「사진」/「파일」 판정이 이 값을 읽는다.
import Foundation

public enum AttachmentFormat {
    /// 파사드 `MAX_ATTACHMENT`(openmls-browser lib.rs)·웹 `MAX_ATTACHMENT` 과 동일.
    public static let maxBytes = 262_144
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
        if starts([0x50, 0x4B, 0x03, 0x04]) { return "application/zip" }
        return fallbackMime
    }

    public static func isImage(mime: String) -> Bool { mime.hasPrefix("image/") }

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
        case "application/zip": return "zip"
        default: return "bin"
        }
    }
}
