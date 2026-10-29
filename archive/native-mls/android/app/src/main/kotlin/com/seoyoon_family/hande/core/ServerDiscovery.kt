// 서버 탐색(#584 PR 3 — 릴레이 `server/wellknown.go` 의 문서, Matrix `.well-known/matrix/client` 방식). 사용자는 도메인 하나만 적는다:
//   1. `https://<host>/.well-known/hande` → 2. `https://hande.<host>/.well-known/hande` → 3. 둘 다 문서가 아니면 입력값을 릴레이 base URL 로 그대로 쓴다.
//   그 다음 `GET <base>/v2/health` 로 릴레이가 맞는지 확인하고, 문서의 `min_app.android` 가 이 앱보다 높으면 「앱이 오래됨」으로 막는다.
// 이 파일은 android.* 를 쓰지 않는다 — 전송은 `fetch` 로 주입(앱은 `OkHttpTransport.get`)하고 JVM 단위 테스트(`ServerDiscoveryTest`)로 고정한다.
// 문서는 외부 입력이다: `StrictJson` 으로 엄격히 읽고 version 1 · https `relay.base_url` 이 아니면 문서가 없는 것과 같이 다룬다.
//
//   {"version":1,"relay":{"base_url":"https://relay.example","app_login":"/v2/app-login"},
//    "hande":{"web_url":"https://hande.example"}?, "name":"서윤 가족"?, "min_app":{"ios":"0.1.0"?,"android":"0.1.0"?}?}
package com.seoyoon_family.hande.core

import java.net.URI
import java.net.URISyntaxException
import kotlin.coroutines.cancellation.CancellationException

object ServerDiscovery {
    const val WELL_KNOWN_PATH = "/.well-known/hande"
    const val HEALTH_PATH = "/v2/health"
    const val VERSION = 1
    /** 문서 상한 — 릴레이 문서는 수백 바이트. 그보다 크면 문서가 아니다(`OkHttpTransport.get` 도 여기까지만 읽는다). */
    const val MAX_DOC_BYTES = 16 * 1024
    const val MAX_NAME_CHARS = 64

    /** 검증을 통과한 `.well-known/hande`. `baseUrl` 은 정규형(호스트 소문자, 끝 `/` 없음). */
    data class WellKnown(val baseUrl: String, val appLogin: String, val webUrl: String?, val name: String?, val minIos: String?, val minAndroid: String?)

    /** 주입 전송의 응답: 상태코드 + 본문(UTF-8). 응답이 없으면(연결 실패·타임아웃) throw — 탐색은 다음 후보로 넘어간다. */
    data class Fetched(val status: Int, val body: String)

    sealed interface Result {
        /**
         * 찾았다. `wellKnown` 이 null 이면 문서가 없어 입력값을 릴레이로 바로 쓴 것. `healthOk` = `/v2/health` 가 `{"ok":true}` 였다;
         * false 면 엣지(CF Access)가 302/401/403 으로 가렸다 — 릴레이는 그 뒤에 있으니 저장하고 가족 로그인으로 이어진다.
         */
        data class Found(val baseUrl: String, val name: String?, val wellKnown: WellKnown?, val healthOk: Boolean) : Result
        /** 입력을 주소로 읽을 수 없다(호스트 없음 · http 인데 localhost 가 아님 · userinfo 등). */
        data object BadInput : Result
        /** 서버가 이 앱(`current`)보다 높은 버전(`required`)을 요구한다. */
        data class TooOld(val baseUrl: String, val name: String?, val required: String, val current: String) : Result
        /** base 는 정했지만 `/v2/health` 가 릴레이 응답이 아니다(`detail` = `status <n>` 또는 전송 오류). */
        data class Unreachable(val baseUrl: String, val detail: String) : Result
    }

    private val SEMVER_LOOSE = Regex("^[0-9]+(\\.[0-9]+){0,2}$") // 릴레이 `semverLoose` 와 같다
    private val IPV4 = Regex("^[0-9]+(\\.[0-9]+){3}$")
    /** 엣지 인증이 가린 모양(`DeviceHub.EDGE_AUTH` 와 같은 상태들). */
    private val EDGE_STATUSES = setOf(301, 302, 303, 307, 308, 401, 403)

    /**
     * 입력(도메인 또는 URL) → 릴레이 base URL 정규형: 스킴이 없으면 `https://`, 호스트 소문자, 끝 `/` 제거, query/fragment 버림, 포트·경로 접두 유지.
     * https 만 — http 는 localhost/127.0.0.1 만(개발). userinfo, `//`·`..` 가 든 경로는 거부. 못 읽으면 null.
     */
    fun normalizeBase(input: String): String? {
        var s = input.trim()
        if (s.isEmpty()) return null
        if ("://" !in s) s = "https://$s"
        val u = try { URI(s) } catch (_: URISyntaxException) { return null }
        val scheme = u.scheme?.lowercase() ?: return null
        val host = u.host?.lowercase()?.trimEnd('.')?.takeIf { it.isNotEmpty() } ?: return null
        when (scheme) {
            "https" -> {}
            "http" -> if (host != "localhost" && host != "127.0.0.1") return null
            else -> return null
        }
        if (u.rawUserInfo != null) return null
        val path = (u.rawPath ?: "").trimEnd('/')
        if (path.isNotEmpty() && (!path.startsWith("/") || "//" in path || ".." in path.split('/'))) return null
        val port = if (u.port == -1) "" else ":${u.port}"
        return "$scheme://$host$port$path"
    }

    /**
     * 탐색 후보(순서대로): `<scheme>://<host[:port]>/.well-known/hande`, 그리고 https 이고 호스트가 이미 `hande.` 로 시작하거나 IP 가 아니면
     * `hande.<host>` 쪽도. 입력의 경로는 무시한다 — well-known 은 호스트 루트에 있다(RFC 8615). 입력이 주소가 아니면 빈 목록.
     */
    fun candidates(input: String): List<String> {
        val base = normalizeBase(input) ?: return emptyList()
        val u = URI(base)
        val host = u.host
        val port = if (u.port == -1) "" else ":${u.port}"
        val out = ArrayList<String>(2)
        out += "${u.scheme}://$host$port$WELL_KNOWN_PATH"
        if (u.scheme == "https" && !host.startsWith("hande.") && !host.startsWith("[") && !IPV4.matches(host)) {
            out += "${u.scheme}://hande.$host$port$WELL_KNOWN_PATH"
        }
        return out
    }

    /**
     * 문서를 엄격히 읽는다 — 아니면 null(= 문서 없음, 다음 후보로): JSON 객체 · `version` == 1 · `relay.base_url` 이 스킴 있는 https 주소
     * (http 는 localhost 만, 릴레이 `publicBaseURL` 과 같은 규칙) · 있으면 `relay.app_login` 은 `/` 로 시작 · `hande.web_url` 은 https 주소 ·
     * `min_app.ios`/`android` 는 `0.1.0` 꼴. 모르는 키는 무시(앞으로의 version 1 추가 필드). `name` 은 표시용이라 거부하지 않고 다듬는다
     * (제어 문자 제거 · 64자). JSON `null` 은 없는 것과 같다.
     */
    fun parseWellKnown(json: String): WellKnown? {
        if (json.length > MAX_DOC_BYTES) return null
        val doc = (try { StrictJson(json).parseDocument() } catch (_: StrictJson.Malformed) { null }) as? Map<*, *> ?: return null
        if ((field(doc, "version") as? StrictJson.Num)?.value != VERSION.toDouble()) return null
        val relay = field(doc, "relay") as? Map<*, *> ?: return null
        val baseUrl = (field(relay, "base_url") as? String)?.let { absoluteBase(it) } ?: return null
        val appLogin = when (val v = field(relay, "app_login")) {
            null -> AppLogin.PATH
            is String -> v.takeIf { it.startsWith("/") && it.length <= 256 && it.none { c -> c <= ' ' } } ?: return null
            else -> return null
        }
        val webUrl = when (val h = field(doc, "hande")) {
            null -> null
            is Map<*, *> -> when (val w = field(h, "web_url")) {
                null -> null
                is String -> absoluteBase(w) ?: return null
                else -> return null
            }
            else -> return null
        }
        val name = when (val n = field(doc, "name")) {
            null -> null
            is String -> displayName(n)
            else -> return null
        }
        var minIos: String? = null
        var minAndroid: String? = null
        when (val m = field(doc, "min_app")) {
            null -> {}
            is Map<*, *> -> {
                minIos = version(field(m, "ios")) ?: return null
                minAndroid = version(field(m, "android")) ?: return null
                if (minIos.isEmpty()) minIos = null
                if (minAndroid.isEmpty()) minAndroid = null
            }
            else -> return null
        }
        return WellKnown(baseUrl, appLogin, webUrl, name, minIos, minAndroid)
    }

    /** 느슨한 semver 비교(`0.1.0` 꼴): `.` 로 나눠 숫자로 견주고 빠진 자리는 0. `-beta`·`+build` 는 무시, 숫자가 아니면 0. 음수 = a < b. */
    fun compareVersions(a: String, b: String): Int {
        val pa = versionParts(a)
        val pb = versionParts(b)
        for (i in 0 until maxOf(pa.size, pb.size)) {
            val x = pa.getOrElse(i) { 0L }
            val y = pb.getOrElse(i) { 0L }
            if (x != y) return x.compareTo(y)
        }
        return 0
    }

    /** `/v2/health` 본문이 `{"ok":true}` 인가(다른 키는 무시). */
    fun healthOk(body: String): Boolean =
        ((try { StrictJson(body).parseDocument() } catch (_: StrictJson.Malformed) { null }) as? Map<*, *>)?.get("ok") == true

    /**
     * 탐색 전체. `fetch` 는 GET 한 번(리다이렉트 무추적) — 응답이 없으면 throw 해도 된다(후보는 건너뛰고, health 는 [Result.Unreachable]).
     * 문서를 찾으면 그 `relay.base_url`·`name` 을, 아니면 입력값을 base 로 쓴다. 그 뒤 `min_app.android` 검사 → `/v2/health`.
     */
    suspend fun discover(input: String, appVersion: String, fetch: suspend (String) -> Fetched): Result {
        val direct = normalizeBase(input) ?: return Result.BadInput
        var wellKnown: WellKnown? = null
        for (url in candidates(input)) {
            val r = try { fetch(url) } catch (e: CancellationException) { throw e } catch (_: Exception) { continue }
            if (r.status != 200) continue
            wellKnown = parseWellKnown(r.body) ?: continue
            break
        }
        val base = wellKnown?.baseUrl ?: direct
        val name = wellKnown?.name
        val required = wellKnown?.minAndroid
        if (required != null && compareVersions(appVersion, required) < 0) return Result.TooOld(base, name, required, appVersion)
        val health = try {
            fetch(base + HEALTH_PATH)
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            return Result.Unreachable(base, e.message?.takeIf { it.isNotBlank() } ?: e.javaClass.simpleName)
        }
        return when {
            health.status == 200 && healthOk(health.body) -> Result.Found(base, name, wellKnown, healthOk = true)
            health.status in EDGE_STATUSES -> Result.Found(base, name, wellKnown, healthOk = false)
            else -> Result.Unreachable(base, "status ${health.status}")
        }
    }

    // ---- 보조 ----

    /** 객체의 키 — 없거나 JSON `null` 이면 null. */
    private fun field(obj: Map<*, *>, key: String): Any? = obj[key]?.takeUnless { it is StrictJson.Null }

    /** 문서 안의 주소는 스킴이 있어야 한다(도메인만 적는 것은 사용자 입력의 편의일 뿐). */
    private fun absoluteBase(s: String): String? = if ("://" in s) normalizeBase(s) else null

    private fun displayName(raw: String): String? =
        raw.filter { it >= ' ' && it != '\u007f' }.trim().take(MAX_NAME_CHARS).takeIf { it.isNotEmpty() }

    /** 없으면 ""(호출자가 null 로), 문자열이고 `0.1.0` 꼴이면 그 값, 아니면 null(문서 거부). */
    private fun version(v: Any?): String? = when (v) {
        null -> ""
        is String -> v.trim().takeIf { it.isEmpty() || SEMVER_LOOSE.matches(it) }
        else -> null
    }

    private fun versionParts(v: String): List<Long> =
        v.trim().substringBefore('-').substringBefore('+').split('.').map { p -> p.takeWhile { it in '0'..'9' }.take(12).toLongOrNull() ?: 0L }
}
