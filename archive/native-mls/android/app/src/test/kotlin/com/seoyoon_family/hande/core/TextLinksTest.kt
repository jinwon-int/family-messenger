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
}
