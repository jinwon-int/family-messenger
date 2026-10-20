// 가족 로그인 순수 로직(#338 B2 — iOS `FamilyChat/App/AppLogin.swift` §12-C A 와 같은 프로토콜). 앱은 비밀번호도 쿠키도 직접 다루지 않는다:
//   1. 앱이 난수 `state` 를 만들고 **시스템 브라우저**(Chrome Custom Tabs, `LoginLauncher`)로 릴레이 `GET /v2/app-login?state=…` 를 연다
//      (Google 은 앱 내 WebView 로그인을 막지만 Custom Tabs 는 브라우저 본체라 허용한다).
//   2. 엣지(Cloudflare Access)가 평소대로 Google 로그인을 처리하고 `Cf-Access-Jwt-Assertion` 을 주입한다.
//   3. 릴레이(server/applogin.go)가 그 토큰을 검증한 뒤 **고정 스킴** `hande://auth#jwt=…&state=…` 로 302 — 브라우저가 이 앱의
//      intent-filter(`MainActivity`, singleTask)로 돌려준다(fragment 라 서버 로그에 남지 않는다).
//   4. 앱은 `state` 가 자기 것인지 확인하고 JWT 를 `Settings.accessToken` 으로 쓴다 — 붙여넣기 흐름과 같은 토큰·같은 권한.
// 이 파일은 android.* 를 쓰지 않는다 — JVM 단위 테스트(`AppLoginTest`)로 고정한다. 콜백은 외부 입력이므로 관대한 파서를 쓴다.
package com.seoyoon_family.hande.core

import java.net.URI
import java.net.URISyntaxException
import java.net.URLDecoder
import java.security.SecureRandom
import java.util.Base64

object AppLogin {
    /** 릴레이 `appLoginCallback`(`hande://auth`)과 같아야 한다. AndroidManifest 의 intent-filter 에도 같은 스킴·호스트. */
    const val CALLBACK_SCHEME = "hande"
    const val CALLBACK_HOST = "auth"
    const val PATH = "/v2/app-login"

    sealed class Failure(message: String) : Exception(message) {
        /** 릴레이 주소에서 로그인 URL 을 만들 수 없다. */
        object BadRelayUrl : Failure("bad relay url")
        /** 로그인 창을 열 수 없다(브라우저 없음). */
        object CannotStart : Failure("cannot start")
        /** 콜백이 `hande://auth` 가 아니다. */
        object NotCallback : Failure("not callback")
        /** 콜백의 state 가 이 요청의 것이 아니다(없음 포함). */
        object StateMismatch : Failure("state mismatch")
        /** 콜백에 jwt 가 없다(릴레이가 앱 로그인을 지원하지 않거나 응답이 비었다). */
        object MissingToken : Failure("missing token")
        /** jwt 가 `a.b.c` 꼴이 아니다. */
        object MalformedToken : Failure("malformed token")
    }

    /** 32 바이트 난수 → base64url 43자(패딩 없음). 릴레이는 16..128 base64url 만 받는다. */
    fun makeState(random: SecureRandom = SecureRandom()): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also(random::nextBytes))

    /**
     * `<relay>/v2/app-login?state=<state>` — 릴레이 주소의 끝 `/` 와 경로 접두는 `OkHttpTransport` 의 규칙과 같다(`Settings.relayUrl` 은 이미 끝 `/` 를 뗀다).
     * 주소에 query/fragment 가 있으면 버린다. http(s) 가 아니면 null.
     */
    fun loginUrl(relayUrl: String, state: String): String? {
        val u = try { URI(relayUrl.trim()) } catch (_: URISyntaxException) { return null }
        val scheme = u.scheme?.lowercase() ?: return null
        if (scheme != "https" && scheme != "http") return null
        val authority = u.rawAuthority?.takeIf { it.isNotBlank() } ?: return null
        val basePath = (u.rawPath ?: "").trimEnd('/')
        return "$scheme://$authority$basePath$PATH?state=$state"
    }

    /** 콜백 `hande://auth#jwt=…&state=…` 에서 JWT 를 꺼낸다. fragment 만 읽는다(query 의 값은 무시 — 릴레이는 fragment 로만 준다). */
    fun tokenFromCallback(callback: String, expectedState: String): String {
        val u = try { URI(callback) } catch (_: URISyntaxException) { throw Failure.NotCallback }
        if (u.scheme?.lowercase() != CALLBACK_SCHEME || u.host?.lowercase() != CALLBACK_HOST) throw Failure.NotCallback
        val fields = formFields(u.rawFragment ?: "")
        val state = fields["state"]
        if (expectedState.isEmpty() || state == null || state != expectedState) throw Failure.StateMismatch
        val jwt = fields["jwt"]?.takeIf { it.isNotEmpty() } ?: throw Failure.MissingToken
        if (!isJwtShaped(jwt)) throw Failure.MalformedToken
        return jwt
    }

    /** `k=v&k2=v2`(percent-encoded) → 사전. 같은 키가 또 오면 첫 값을 지킨다. 디코딩 실패 쌍은 건너뛴다(외부 입력). */
    fun formFields(encoded: String): Map<String, String> {
        val fields = LinkedHashMap<String, String>()
        for (pair in encoded.split('&')) {
            if (pair.isEmpty()) continue
            val parts = pair.split('=', limit = 2)
            val key = decode(parts[0]) ?: continue
            if (key.isEmpty()) continue
            val value = if (parts.size == 2) decode(parts[1]) ?: "" else ""
            fields.putIfAbsent(key, value)
        }
        return fields
    }

    /** `header.payload.signature` — 세 조각 모두 비어 있지 않은 base64url. 서명 검증은 하지 않는다(엣지·릴레이의 몫). */
    fun isJwtShaped(token: String): Boolean {
        val parts = token.split('.')
        return parts.size == 3 && parts.all { p -> p.isNotEmpty() && p.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_' } }
    }

    /** iOS `removingPercentEncoding` 상당 — `+` 는 공백으로 바꾸지 않는다(fragment 는 form 이 아니다). */
    private fun decode(s: String): String? = try { URLDecoder.decode(s.replace("+", "%2B"), "UTF-8") } catch (_: IllegalArgumentException) { null }
}
