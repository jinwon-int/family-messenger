// x.com 링크 미리보기(#683 2단계, 「2단계 API 계약 v1」 클라이언트 절) — 순수 로직. android.* 없음 → JVM 테스트(`LinkPreviewTest`).
// 대상: 사람 말풍선의 첫 번째 x.com **글(status) 링크**(1단계 `TextLinks.xHosts` 규칙 + 릴레이와 같은 경로 규칙: `/{handle}/status/{id}` ·
// `/i/web/status/{id}`). 요청: `<relay>/v2/preview?url=<URL-encoded>`, 이미지는 응답의 릴레이 상대 경로(`/v2/preview/image?u=…`)만 —
// 절대 주소는 버린다(인증 헤더를 릴레이 밖으로 보내지 않는다). 404/400/502/네트워크 실패/라우트 없음 → 카드 없음(조용히).
// 캐시(앱 메모리, URL 별 한 번): 성공·확정 실패(400·404·200 인데 읽을 수 없음)는 프로세스 동안, 일시 실패(네트워크·5xx·401·302 등)는 10분 뒤 다시.
package com.seoyoon_family.hande.core

import java.net.URI
import java.net.URISyntaxException
import java.net.URLEncoder

object LinkPreview {
    /** 릴레이 응답 `{url,site,title,description,image}`. `image` = 릴레이 상대 경로 또는 null. 빈 문자열 = 없음. */
    data class Card(val url: String, val site: String, val title: String, val description: String, val image: String?)

    /** 응답 한 건(상태코드 + 본문). 본문이 상한을 넘었으면 null. */
    class Fetched(val status: Int, val body: ByteArray?)

    /** 미리보기 결과 — 캐시에 들어가는 값. */
    sealed interface Outcome<out T> {
        data class Hit<T>(val value: T) : Outcome<T>
        /** `permanent` = 같은 URL 을 다시 물어도 같다(400·404·읽을 수 없는 200). 아니면 일시 실패 — TTL 뒤 다시. */
        data class Miss(val permanent: Boolean) : Outcome<Nothing>
    }

    const val PREVIEW_PATH = "/v2/preview"
    const val IMAGE_PATH = "/v2/preview/image"
    /** 미리보기 JSON 상한 — 릴레이는 필드마다 2000자 상한(엔티티 해제 뒤, JSON 이스케이프로 늘어나도 이 안). */
    const val MAX_JSON_BYTES = 64 * 1024
    /** 이미지 상한 — 릴레이와 같은 2 MiB. */
    const val MAX_IMAGE_BYTES = 2 * 1024 * 1024
    private const val MAX_FIELD = 2000

    private val HANDLE = Regex("[A-Za-z0-9_]{1,15}")
    private val STATUS_ID = Regex("[0-9]{1,25}")

    /** `https` x.com 계열(사용자 정보·포트 없음) + 글 경로(`/{handle}/status/{id}[/…]` 또는 `/i/web/status/{id}[/…]`). 질의는 상관없다. */
    fun isStatusUrl(url: String): Boolean {
        if (TextLinks.allowedUrl(url) == null) return false
        val uri = try { URI(url) } catch (_: URISyntaxException) { return false }
        val path = uri.rawPath ?: return false
        if (!path.startsWith("/")) return false
        val seg = path.substring(1).split('/')
        if (seg.size >= 4 && seg[0] == "i" && seg[1] == "web" && seg[2] == "status" && STATUS_ID.matches(seg[3])) return true
        return seg.size >= 3 && HANDLE.matches(seg[0]) && seg[1] == "status" && STATUS_ID.matches(seg[2])
    }

    /** 말풍선 글에서 미리보기를 그릴 링크: 첫 번째 x.com 글 링크. 없으면 null. */
    fun target(text: String): String? = TextLinks.links(text).firstOrNull { isStatusUrl(it.url) }?.url

    /** `<relay>/v2/preview?url=<link>` — 릴레이 주소의 끝 `/`·경로 접두는 `AppLogin.loginUrl` 과 같은 규칙. http(s) 가 아니면 null. */
    fun previewUrl(relayUrl: String, link: String): String? {
        val base = base(relayUrl) ?: return null
        return "$base$PREVIEW_PATH?url=${URLEncoder.encode(link, "UTF-8")}"
    }

    /**
     * 응답 `image`(릴레이 상대 경로)를 받을 주소. `/v2/preview/image?` 로 시작하는 상대 경로만 — 절대 주소·`//host`·공백·제어 문자는 null
     * (인증 헤더가 릴레이 밖으로 나가지 않게).
     */
    fun imageUrl(relayUrl: String, image: String?): String? {
        if (image == null || !image.startsWith("$IMAGE_PATH?")) return null
        if (image.any { it.isWhitespace() || it.isISOControl() || it == '#' || it == '\\' }) return null
        val base = base(relayUrl) ?: return null
        return base + image
    }

    /** 릴레이 JSON 을 엄격히 읽는다(`StrictJson`). 문자열이 아닌 필드는 없는 것으로. 제목·본문이 둘 다 비면 null(그릴 것이 없다). */
    fun parse(json: String): Card? {
        if (json.length > MAX_JSON_BYTES) return null
        val doc = (try { StrictJson(json).parseDocument() } catch (_: StrictJson.Malformed) { null }) as? Map<*, *> ?: return null
        fun text(key: String): String = ((doc[key] as? String) ?: "").trim().take(MAX_FIELD)
        val title = text("title")
        val description = text("description")
        if (title.isEmpty() && description.isEmpty()) return null
        val image = (doc["image"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
        return Card(url = text("url"), site = text("site").ifEmpty { "X" }, title = title, description = description, image = image)
    }

    /** `GET /v2/preview` 응답 → 캐시 값. `fetched == null` = 응답 없음(네트워크 실패·타임아웃). */
    fun outcome(fetched: Fetched?): Outcome<Card> {
        if (fetched == null) return Outcome.Miss(permanent = false)
        return when (fetched.status) {
            200 -> fetched.body?.let { parse(String(it, Charsets.UTF_8)) }?.let { Outcome.Hit(it) } ?: Outcome.Miss(permanent = true)
            400, 404, 410 -> Outcome.Miss(permanent = true) // bad_url · no_preview · 라우트 꺼짐(플래그 off)
            else -> Outcome.Miss(permanent = false) // 502 upstream_failed · 401 세션 만료 · 302 엣지 · 5xx
        }
    }

    private fun base(relayUrl: String): String? {
        val u = try { URI(relayUrl.trim()) } catch (_: URISyntaxException) { return null }
        val scheme = u.scheme?.lowercase() ?: return null
        if (scheme != "https" && scheme != "http") return null
        val authority = u.rawAuthority?.takeIf { it.isNotBlank() } ?: return null
        return "$scheme://$authority${(u.rawPath ?: "").trimEnd('/')}"
    }
}

/**
 * 미리보기 메모리 캐시(URL 별). 성공·확정 실패는 지우기 전까지, 일시 실패는 `missTtlMs` 뒤 없는 것으로. 최대 `maxEntries`(가장 오래 안 쓴 것부터 뺀다).
 * 시계는 호출자가 준다(`now` ms) — 테스트가 시간을 정한다. 스레드 안전(전부 `synchronized`).
 */
class PreviewCache<T>(private val maxEntries: Int = 256, private val missTtlMs: Long = 10 * 60_000L) {
    private class Slot<V>(val outcome: LinkPreview.Outcome<V>, val at: Long)
    private val map = LinkedHashMap<String, Slot<T>>(16, 0.75f, true)

    /** 캐시된 결과. 없거나 일시 실패가 만료됐으면 null(= 다시 물어라). */
    @Synchronized
    fun get(key: String, now: Long): LinkPreview.Outcome<T>? {
        val slot = map[key] ?: return null
        val o = slot.outcome
        if (o is LinkPreview.Outcome.Miss && !o.permanent && now - slot.at >= missTtlMs) {
            map.remove(key)
            return null
        }
        return o
    }

    @Synchronized
    fun put(key: String, outcome: LinkPreview.Outcome<T>, now: Long) {
        map[key] = Slot(outcome, now)
        val iter = map.entries.iterator()
        while (map.size > maxEntries && iter.hasNext()) { iter.next(); iter.remove() }
    }

    @Synchronized
    fun clear() = map.clear()

    @get:Synchronized
    val size: Int get() = map.size
}
