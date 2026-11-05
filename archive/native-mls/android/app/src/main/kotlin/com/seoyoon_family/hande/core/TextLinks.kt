// 말풍선의 링크(#683) — 웹 web/hande/service-links.js · iOS App/ServiceLinks.swift 와 같은 규칙.
// https · 사용자 정보/포트 없음 · 호스트 정확히 일치(소문자) · 주소 끝 문장부호는 뺀다. 사람 말풍선은 x.com 계열만 링크로 바꾸고,
// 에이전트 말풍선은 링크를 만들지 않는다(화면이 고른다). android.* 없음 → JVM 테스트(`TextLinksTest`).
package com.seoyoon_family.hande.core

import java.net.URI
import java.net.URISyntaxException

object TextLinks {
    /** 사람 말풍선에서 링크로 바꿀 x.com 계열 호스트(소문자, 정확히 일치). */
    val xHosts: Set<String> = setOf("x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com")

    /** 글 속 링크 한 개: `[start, end)` 글자 위치(UTF-16, String 색인)와 열 주소. */
    data class Link(val start: Int, val end: Int, val url: String)

    private val candidate = Regex("https://[^\\s<>\"'`]+")
    /** 주소 끝에 붙은 문장부호 — 문장의 일부일 때가 많아 링크에서 뺀다. */
    private const val TRAILING = ".,!?;:)]}'\"…"

    /** `https://…` 한 덩어리가 허용 링크면 그 주소, 아니면 null. */
    fun allowedUrl(text: String, hosts: Set<String> = xHosts): String? {
        val uri = try { URI(text) } catch (_: URISyntaxException) { return null }
        if (uri.scheme?.lowercase() != "https") return null
        if (uri.rawUserInfo != null || uri.port != -1) return null
        val host = uri.host?.lowercase() ?: return null
        return if (host in hosts) text else null
    }

    /** 글 속 허용 링크들. 앞에서부터, 겹치지 않게. */
    fun links(text: String, hosts: Set<String> = xHosts): List<Link> {
        val found = ArrayList<Link>()
        for (match in candidate.findAll(text)) {
            var end = match.range.last + 1
            while (end > match.range.first && text[end - 1] in TRAILING) end--
            if (end <= match.range.first) continue
            val url = allowedUrl(text.substring(match.range.first, end), hosts) ?: continue
            found += Link(match.range.first, end, url)
        }
        return found
    }
}
