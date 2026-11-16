// 말풍선의 링크(#683) — 웹 web/hande/service-links.js · iOS App/ServiceLinks.swift 와 같은 규칙.
// https · 사용자 정보/포트 없음 · 호스트 정확히 일치(소문자) · 주소 끝 문장부호는 뺀다. 사람 말풍선은 허용 호스트만 링크로 바꾸고
// (v2 #690: 릴레이 사이트 목록의 hosts 합집합 — `PreviewSites.Registry.linkHosts`, 못 받으면 폴백 = `xHosts`),
// 에이전트 말풍선은 호스트 제한 없는 `agentLinks`(오너 2026-11-16). android.* 없음 → JVM 테스트(`TextLinksTest`).
package com.seoyoon_family.hande.core

import java.net.URI
import java.net.URISyntaxException

object TextLinks {
    /** x.com 계열 호스트(소문자, 정확히 일치) — 사이트 목록을 못 받았을 때의 폴백(v1) 링크 호스트. */
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

    // ---- 에이전트 말풍선(오너 2026-11-16 「에이전트가 주는 url 은 어떤 주소든 링크로」) ----
    // 호스트 목록 없이 http·https 주소면 모두 링크(포트 허용 — 노드 내부 주소 `http://100.x.y.z:8080` 같은 것).
    // 그래도 막는 것: 다른 스킴(후보 정규식이 http(s) 만 잡는다), 사용자 정보가 붙은 주소(보이는 곳과 가는 곳이 다르다).
    // 웹 service-links.js `agentLinkParts` · iOS `ServiceLinks.agentLinks` 와 같은 규칙·같은 테스트 벡터.

    /** 에이전트 글의 주소 후보. 한국어 글에서 주소를 감싸는 낫표·괄호(「」『』【】〈〉《》（）)에서 끊는다. */
    private val agentCandidate = Regex("https?://[^\\s<>\"'`「」『』【】〈〉《》（）]+", RegexOption.IGNORE_CASE)
    /** 에이전트 주소 끝에서 떼어 낼 문장부호 — 사람 말풍선 규칙 + 한국어 마침표·쉼표. */
    private const val AGENT_TRAILING = TRAILING + "。、，"

    /** 에이전트 글의 `http(s)://…` 한 덩어리가 열 수 있는 주소면 그 주소, 아니면 null(호스트 제한 없음). */
    fun agentUrl(text: String): String? {
        val uri = try { URI(text) } catch (_: URISyntaxException) { return null }
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && scheme != "http") return null
        if (uri.rawUserInfo != null) return null
        if (uri.host.isNullOrEmpty()) return null
        return text
    }

    /** 에이전트 글 속 링크들. 앞에서부터, 겹치지 않게. 끝 `)` 는 주소 안에 짝이 되는 `(` 가 있으면 남긴다(위키백과 `Foo_(bar)`). */
    fun agentLinks(text: String): List<Link> {
        val found = ArrayList<Link>()
        for (match in agentCandidate.findAll(text)) {
            val start = match.range.first
            var end = match.range.last + 1
            while (end > start && text[end - 1] in AGENT_TRAILING) {
                if (text[end - 1] == ')') {
                    val head = text.substring(start, end)
                    if (head.count { it == '(' } >= head.count { it == ')' }) break
                }
                end--
            }
            if (end <= start) continue
            val url = agentUrl(text.substring(start, end)) ?: continue
            found += Link(start, end, url)
        }
        return found
    }
}
