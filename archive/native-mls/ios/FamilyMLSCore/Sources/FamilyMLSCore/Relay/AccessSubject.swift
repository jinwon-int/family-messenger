// CF Access JWT 의 `sub` 읽기 — 등록 JSON(`EnrollmentRequest.subject`, DEVICES-V4 §필드 필수)을 앱이 스스로 채우기 위한 것.
// 서명 검증은 하지 않는다(엣지·릴레이 `server/auth.go` 가 한다): 여기서 읽은 값은 운영자가 CLI 에 넣는 공개 식별자일 뿐이고,
// 릴레이는 등록된 subject 와 실제 JWT 의 `sub` 가 다르면 403 `device_subject_mismatch` 로 거부하므로 잘못 채워도 권한이 생기지 않는다.
import Foundation

public enum AccessJWT {
    /// `header.payload.signature` 의 payload(base64url JSON)에서 비어 있지 않은 `sub` 를 돌려준다.
    /// JWT 꼴이 아니거나(서비스 토큰처럼) `sub` 가 비어 있으면 nil — 호출자는 subject 를 비워 두고 운영자가 채운다.
    public static func subject(of token: String) -> String? {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = base64URLDecode(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sub = object["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch base64.count % 4 {
        case 2: base64 += "=="
        case 3: base64 += "="
        case 1: return nil
        default: break
        }
        return Data(base64Encoded: base64)
    }
}

public extension RelayCredential {
    /// 자격증명에 실린 JWT 의 `sub`(CF Access 사용자 식별자). 서비스 토큰(`sub` 빈값)·JWT 가 아닌 값이면 nil.
    var accessSubject: String? {
        switch self {
        case .accessCookie(let jwt), .bearer(let jwt):
            return AccessJWT.subject(of: jwt)
        }
    }
}
