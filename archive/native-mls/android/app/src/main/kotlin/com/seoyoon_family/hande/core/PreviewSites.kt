// 미리보기 사이트 v2(#690 「계약 v2」 클라이언트 절) — 순수 로직. android.* 없음 → JVM 테스트(`PreviewSitesTest`).
// 릴레이 `GET /v2/preview/sites` → `{"version":2,"sites":[{"id","name","hosts":[…],"preview":bool}, …]}` 를 엄격히 읽어(`StrictJson`)
// 말풍선 링크 호스트(모든 sites 의 hosts 합집합)와 카드 대상(preview:true 사이트에 속하는 첫 링크)을 정한다. 경로 규칙 판정은 릴레이가 한다
// (v2 모드에서는 링크를 그대로 `/v2/preview?url=` 로 보낸다). 받지 못하면(실패·404·옛 릴레이·플래그 꺼짐) 내장 폴백 = v1 동작
// (x.com 계열 호스트만 링크 + x status 경로 규칙의 첫 링크만 카드, `LinkPreview.target`). x status 경로 규칙은 폴백에만 남는다.
package com.seoyoon_family.hande.core

import java.net.URI
import java.net.URISyntaxException
import java.util.Locale

object PreviewSites {
    /** 사이트 한 건. `hosts` = 소문자 평범한 호스트 이름(정확히 일치). `preview = false` 면 링크만(카드 없음). */
    data class Site(val id: String, val name: String, val hosts: Set<String>, val preview: Boolean)

    /**
     * 이 세션의 사이트 목록. `fallback = true` = 릴레이 목록을 못 받은 내장 v1 동작(카드 대상은 x status 경로 규칙).
     * data class — 화면이 `remember` 키로 쓴다(목록이 바뀌면 보이는 말풍선이 다시 그려진다).
     */
    data class Registry(val sites: List<Site>, val fallback: Boolean) {
        /** 말풍선에서 링크로 바꿀 호스트 = 모든 사이트 hosts 의 합집합(링크만 사이트 포함). */
        val linkHosts: Set<String> = sites.flatMapTo(LinkedHashSet()) { it.hosts }

        /** 호스트 → 사이트. 두 사이트가 같은 호스트를 적었으면 앞의 것. */
        private val byHost: Map<String, Site> = HashMap<String, Site>().also { m -> for (s in sites) for (h in s.hosts) m.putIfAbsent(h, s) }

        /** 링크(허용 규칙 통과)가 속한 사이트. 아니면 null. */
        fun siteOf(url: String): Site? {
            if (TextLinks.allowedUrl(url, linkHosts) == null) return null
            val host = try { URI(url).host } catch (_: URISyntaxException) { null } ?: return null
            return byHost[host.lowercase(Locale.ROOT)]
        }

        /** 글 속 링크들(사람·서비스 말풍선용 — 에이전트 말풍선은 화면이 링크를 만들지 않는다). */
        fun links(text: String): List<TextLinks.Link> = TextLinks.links(text, linkHosts)

        /**
         * 카드 대상: v2 = preview:true 사이트에 속하는 **첫 링크 그대로**(경로 판정은 릴레이 — 400 이면 카드 없음, URL 별 음성 캐시).
         * 폴백 = v1 규칙(첫 x status 링크). 없으면 null.
         */
        fun target(text: String): String? =
            if (fallback) LinkPreview.target(text) else links(text).firstOrNull { siteOf(it.url)?.preview == true }?.url
    }

    const val SITES_PATH = "/v2/preview/sites"
    const val VERSION = 2
    /** 사이트 목록 JSON 상한 — 계약 표(8개 사이트)는 1 KiB 남짓. */
    const val MAX_JSON_BYTES = 64 * 1024
    /** 받아들이는 사이트·사이트당 호스트 수 상한(넘는 것은 버린다). */
    const val MAX_SITES = 64
    const val MAX_HOSTS_PER_SITE = 32
    private const val MAX_NAME = 64

    private val ID = Regex("[a-z0-9][a-z0-9_-]{0,31}")
    /** 평범한 DNS 호스트 이름(소문자로 바꾼 뒤): 라벨 1–63자 영숫자·하이픈(앞뒤 하이픈 없음), 점 하나 이상, 끝 점·포트·와일드카드·스킴 없음. */
    private val HOST = Regex("(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+")

    /** 내장 폴백 = v1: x.com 계열 호스트, 카드는 x status 규칙. */
    val FALLBACK: Registry = Registry(listOf(Site("x", "X", TextLinks.xHosts, preview = true)), fallback = true)

    /** `<relay>/v2/preview/sites` — 릴레이 주소 규칙은 `LinkPreview.previewUrl` 과 같다. http(s) 가 아니면 null. */
    fun sitesUrl(relayUrl: String): String? = LinkPreview.base(relayUrl)?.let { it + SITES_PATH }

    /**
     * 사이트 목록 JSON 을 엄격히 읽는다. 문서가 깨졌거나(`StrictJson` — 같은 키 두 번·끝 쉼표 등 포함) 객체가 아니거나 `version != 2` 이거나
     * `sites` 가 배열이 아니면 null. 항목은 하나씩: 모양이 어긋난 항목(id·name·hosts·preview 누락/타입 틀림, 쓸 수 있는 호스트 0개, 앞에서 본 id)은
     * 버린다. 호스트는 소문자로 바꾼 뒤 평범한 호스트 이름만 남긴다. 남은 사이트가 하나도 없으면 null(→ 폴백).
     */
    fun parse(json: String): Registry? {
        if (json.length > MAX_JSON_BYTES) return null
        val doc = (try { StrictJson(json).parseDocument() } catch (_: StrictJson.Malformed) { null }) as? Map<*, *> ?: return null
        val version = doc["version"] as? StrictJson.Num ?: return null
        if (version.value != VERSION.toDouble()) return null
        val entries = doc["sites"] as? List<*> ?: return null
        val sites = ArrayList<Site>()
        val seen = HashSet<String>()
        for (entry in entries) {
            if (sites.size >= MAX_SITES) break
            val site = site(entry) ?: continue
            if (!seen.add(site.id)) continue
            sites += site
        }
        return if (sites.isEmpty()) null else Registry(sites, fallback = false)
    }

    /** `GET /v2/preview/sites` 응답 → 결과. 분류는 카드와 같다(`LinkPreview.outcome`): 200 인데 못 읽음·400·404·410 = 확정, 그 밖 = 일시. */
    fun outcome(fetched: LinkPreview.Fetched?): LinkPreview.Outcome<Registry> {
        if (fetched == null) return LinkPreview.Outcome.Miss(permanent = false)
        return when (fetched.status) {
            200 -> fetched.body?.let { parse(String(it, Charsets.UTF_8)) }?.let { LinkPreview.Outcome.Hit(it) } ?: LinkPreview.Outcome.Miss(permanent = true)
            400, 404, 410 -> LinkPreview.Outcome.Miss(permanent = true) // 옛 릴레이 · 플래그 꺼짐
            else -> LinkPreview.Outcome.Miss(permanent = false) // 401 세션 만료 · 302 엣지 · 5xx
        }
    }

    /** 평범한 호스트 이름이면 소문자형, 아니면 null. */
    fun normalizeHost(raw: String): String? = raw.lowercase(Locale.ROOT).takeIf { HOST.matches(it) }

    private fun site(entry: Any?): Site? {
        val o = entry as? Map<*, *> ?: return null
        val id = (o["id"] as? String)?.takeIf { ID.matches(it) } ?: return null
        val name = (o["name"] as? String)?.trim()?.takeIf { it.isNotEmpty() && it.length <= MAX_NAME && it.none(Char::isISOControl) } ?: return null
        val rawHosts = o["hosts"] as? List<*> ?: return null
        val preview = o["preview"] as? Boolean ?: return null
        val hosts = LinkedHashSet<String>()
        for (h in rawHosts) {
            if (hosts.size >= MAX_HOSTS_PER_SITE) break
            normalizeHost(h as? String ?: continue)?.let { hosts += it }
        }
        if (hosts.isEmpty()) return null
        return Site(id, name, hosts, preview)
    }
}
