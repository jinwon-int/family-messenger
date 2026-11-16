// 말풍선 링크(#683) — 웹 tests/service-links.test.mjs · iOS ServiceLinksTests 와 같은 경우들. android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TextLinksTest {
    private fun urls(text: String) = TextLinks.links(text).map { it.url }

    @Test fun xLinksBecomeLinksWithExactRanges() {
        val text = "이거 봐 https://x.com/jack/status/20 그리고 https://twitter.com/i/web/status/1?s=20."
        val links = TextLinks.links(text)
        assertEquals(listOf("https://x.com/jack/status/20", "https://twitter.com/i/web/status/1?s=20"), links.map { it.url })
        for (l in links) assertEquals(l.url, text.substring(l.start, l.end))
    }

    @Test fun trailingPunctuationIsNotPartOfTheLink() {
        assertEquals(listOf("https://x.com/a/status/1"), urls("보기: https://x.com/a/status/1). 끝"))
    }

    @Test fun allXHostVariants() {
        for (host in listOf("x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com", "X.COM")) {
            assertNotNull(TextLinks.allowedUrl("https://$host/a/status/1"), host)
        }
    }

    @Test fun otherSchemesHostsUserInfoAndPortsStayText() {
        for (bad in listOf(
            "https://www.instagram.com/p/A/",
            "http://x.com/a/status/1",
            "https://x.com.evil.example/a",
            "https://evilx.com/a",
            "https://t.co/abc",
            "https://user@x.com/a",
            "https://x.com:444/a",
            "x.com/a/status/1",
        )) {
            assertTrue(urls("보기 $bad 끝").isEmpty(), bad)
        }
        assertNull(TextLinks.allowedUrl("javascript:alert(1)"))
        assertNull(TextLinks.allowedUrl("https://"))
        assertFalse("instagram.com" in TextLinks.xHosts)
    }

    @Test fun plainAndEmptyText() {
        assertTrue(TextLinks.links("그냥 글").isEmpty())
        assertTrue(TextLinks.links("").isEmpty())
    }

    // ---- 에이전트 말풍선(오너 2026-11-16) — 호스트 제한 없이 http·https. 웹 tests/service-links.test.mjs · iOS ServiceLinksTests 와 같은 벡터. ----

    private fun agentUrls(text: String) = TextLinks.agentLinks(text).map { it.url }

    @Test fun agentLinksAnyHostHttpAndPort() {
        val text = "PR https://github.com/jinwon-int/family-messenger/pull/825 · 대시보드 http://100.64.0.1:8080/status 그리고 https://example.org"
        val links = TextLinks.agentLinks(text)
        assertEquals(
            listOf("https://github.com/jinwon-int/family-messenger/pull/825", "http://100.64.0.1:8080/status", "https://example.org"),
            links.map { it.url },
        )
        for (l in links) assertEquals(l.url, text.substring(l.start, l.end))
    }

    @Test fun agentLinksTrimPunctuationAndKoreanBrackets() {
        val cases = listOf(
            "확인: https://a.example/x." to "https://a.example/x",
            "(https://a.example/x)" to "https://a.example/x",
            "「https://a.example/x」 참고" to "https://a.example/x",
            "주소（https://a.example/x）" to "https://a.example/x",
            "https://a.example/x。" to "https://a.example/x",
            "https://ko.wikipedia.org/wiki/Foo_(bar) 보기" to "https://ko.wikipedia.org/wiki/Foo_(bar)",
            "(위키 https://ko.wikipedia.org/wiki/Foo_(bar))" to "https://ko.wikipedia.org/wiki/Foo_(bar)",
        )
        for ((text, url) in cases) assertEquals(listOf(url), agentUrls(text), text)
    }

    @Test fun agentLinksRejectOtherSchemesAndUserInfo() {
        for (bad in listOf("javascript:alert(1)", "data:text/html,x", "ftp://a.example/x", "https://bank.example@evil.example/a",
                           "https://u:p@a.example/", "https://", "hande-alert://3")) {
            assertTrue(TextLinks.agentLinks("보기 $bad 끝").isEmpty(), bad)
        }
        assertNull(TextLinks.agentUrl("javascript:alert(1)"))
        assertNotNull(TextLinks.agentUrl("http://100.64.0.1:8080/x"))
        assertTrue(TextLinks.agentLinks("주소 없음").isEmpty())
    }
}
