// x.com 링크 미리보기(#683 2단계, 계약 v1 클라이언트 절) — 대상 링크 표 · 요청 주소 · JSON 읽기 · 결과 분류 · 캐시(부정 결과 포함). android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LinkPreviewTest {
    @Test fun targetTable() {
        val cases = listOf(
            "봐 https://x.com/jack/status/20" to "https://x.com/jack/status/20",
            "https://twitter.com/i/web/status/1?s=20." to "https://twitter.com/i/web/status/1?s=20",
            "https://mobile.x.com/a_b/status/123/photo/1 끝" to "https://mobile.x.com/a_b/status/123/photo/1",
            // 첫 x.com 링크가 글 링크가 아니면 다음 글 링크
            "https://x.com/home 그리고 https://x.com/b/status/9" to "https://x.com/b/status/9",
            // 글 링크가 둘이면 첫 번째
            "https://x.com/a/status/1 https://x.com/b/status/2" to "https://x.com/a/status/1",
            "(https://www.twitter.com/Abc/status/42)" to "https://www.twitter.com/Abc/status/42",
            "https://X.COM/a/status/1" to "https://X.COM/a/status/1",
        )
        for ((text, want) in cases) assertEquals(want, LinkPreview.target(text), text)
    }

    @Test fun nonStatusLinksHaveNoTarget() {
        for (text in listOf(
            "그냥 글",
            "",
            "https://x.com/jack",
            "https://x.com/jack/status/",
            "https://x.com/jack/status/abc",
            "https://x.com/jack/statuses/1",
            "https://x.com/i/web/status/x1",
            "https://x.com/this_handle_is_too_long/status/1", // handle 16자 이상
            "https://x.com/a-b/status/1",
            "https://x.com/a/status/12345678901234567890123456", // id 26자리
            "http://x.com/a/status/1",
            "https://x.com:444/a/status/1",
            "https://user@x.com/a/status/1",
            "https://evilx.com/a/status/1",
            "https://www.instagram.com/a/status/1",
        )) {
            assertNull(LinkPreview.target(text), text)
        }
        assertTrue(LinkPreview.isStatusUrl("https://x.com/a/status/1234567890123456789012345"))
        assertFalse(LinkPreview.isStatusUrl("https://x.com/a/status/1234567890123456789012345x"))
    }

    @Test fun previewUrlEncodesTheLinkAndKeepsTheRelayPrefix() {
        assertEquals(
            "https://relay.example/v2/preview?url=https%3A%2F%2Fx.com%2Fa%2Fstatus%2F1%3Fs%3D20%26t%3Dx",
            LinkPreview.previewUrl("https://relay.example/", "https://x.com/a/status/1?s=20&t=x"),
        )
        assertEquals("https://relay.example/hande/v2/preview?url=https%3A%2F%2Fx.com%2Fa%2Fstatus%2F1", LinkPreview.previewUrl("https://relay.example/hande/", "https://x.com/a/status/1"))
        assertEquals("http://10.0.2.2:8080/v2/preview?url=https%3A%2F%2Fx.com%2Fa%2Fstatus%2F1", LinkPreview.previewUrl("http://10.0.2.2:8080", "https://x.com/a/status/1"))
        assertNull(LinkPreview.previewUrl("ftp://relay.example", "https://x.com/a/status/1"))
        assertNull(LinkPreview.previewUrl("relay.example", "https://x.com/a/status/1"))
    }

    @Test fun imageUrlOnlyFollowsRelayRelativePaths() {
        val path = "/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%2Fmedia%2Fa.jpg"
        assertEquals("https://relay.example$path", LinkPreview.imageUrl("https://relay.example/", path))
        assertEquals("https://relay.example/hande$path", LinkPreview.imageUrl("https://relay.example/hande", path))
        for (bad in listOf(
            null,
            "",
            "https://pbs.twimg.com/media/a.jpg",
            "//evil.example/v2/preview/image?u=x",
            "/v2/preview/image",
            "/v2/preview?url=x",
            "/v2/other",
            "/v2/preview/image?u=a b",
            "/v2/preview/image?u=a\r\nX: y",
            "/v2/preview/image?u=a#frag",
        )) {
            assertNull(LinkPreview.imageUrl("https://relay.example", bad), bad.toString())
        }
    }

    @Test fun parseFullResponse() {
        val card = LinkPreview.parse(
            """{"url":"https://x.com/a/status/1","site":"X","title":"제목 \"따옴\"","description":"줄1\n줄2 é","image":"/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%2Fx.jpg"}""",
        )
        assertNotNull(card)
        assertEquals("https://x.com/a/status/1", card.url)
        assertEquals("X", card.site)
        assertEquals("제목 \"따옴\"", card.title)
        assertEquals("줄1\n줄2 é", card.description)
        assertEquals("/v2/preview/image?u=https%3A%2F%2Fpbs.twimg.com%2Fx.jpg", card.image)
    }

    @Test fun parseImageNullOrMissing() {
        assertNull(LinkPreview.parse("""{"url":"u","site":"X","title":"t","description":"d","image":null}""")!!.image)
        assertNull(LinkPreview.parse("""{"url":"u","site":"X","title":"t","description":"d"}""")!!.image)
        assertNull(LinkPreview.parse("""{"title":"t","image":""}""")!!.image)
        assertNull(LinkPreview.parse("""{"title":"t","image":42}""")!!.image)
    }

    @Test fun parseMissingFields() {
        val onlyTitle = LinkPreview.parse("""{"title":"  제목  "}""")!!
        assertEquals("제목", onlyTitle.title)
        assertEquals("", onlyTitle.description)
        assertEquals("", onlyTitle.url)
        assertEquals("X", onlyTitle.site, "site 가 없으면 X")
        assertEquals("본문", LinkPreview.parse("""{"description":"본문","title":null}""")!!.description)
        assertEquals("", LinkPreview.parse("""{"description":"본문","title":7}""")!!.title, "문자열이 아니면 없는 것")
        // 그릴 것이 없다
        assertNull(LinkPreview.parse("""{"url":"u","site":"X","title":"","description":"  ","image":"/v2/preview/image?u=x"}"""))
        assertNull(LinkPreview.parse("""{}"""))
        // 잘못된 문서
        for (bad in listOf("", "null", "[]", "\"t\"", "{\"title\":\"t\",}", "{\"title\":\"a\",\"title\":\"b\"}", "<html>", "{\"title\":\"t\"} x")) {
            assertNull(LinkPreview.parse(bad), bad)
        }
        assertEquals(2000, LinkPreview.parse("""{"title":"${"가".repeat(2500)}"}""")!!.title.length, "필드 2000자 상한")
        assertNull(LinkPreview.parse("{\"title\":\"" + "a".repeat(LinkPreview.MAX_JSON_BYTES) + "\"}"), "문서 상한")
    }

    @Test fun outcomeClassification() {
        val ok = """{"url":"u","site":"X","title":"t","description":"d","image":null}""".toByteArray()
        val hit = LinkPreview.outcome(LinkPreview.Fetched(200, ok))
        assertTrue(hit is LinkPreview.Outcome.Hit<LinkPreview.Card> && hit.value.title == "t" && hit.value.image == null)
        assertEquals(LinkPreview.Outcome.Miss(permanent = false), LinkPreview.outcome(null), "응답 없음 = 일시")
        assertEquals(LinkPreview.Outcome.Miss(permanent = true), LinkPreview.outcome(LinkPreview.Fetched(404, """{"error":"no_preview"}""".toByteArray())), "no_preview")
        assertEquals(LinkPreview.Outcome.Miss(permanent = true), LinkPreview.outcome(LinkPreview.Fetched(404, "404 page not found".toByteArray())), "라우트 꺼짐")
        assertEquals(LinkPreview.Outcome.Miss(permanent = true), LinkPreview.outcome(LinkPreview.Fetched(400, """{"error":"bad_url"}""".toByteArray())))
        assertEquals(LinkPreview.Outcome.Miss(permanent = true), LinkPreview.outcome(LinkPreview.Fetched(200, "<html>".toByteArray())), "읽을 수 없는 200")
        assertEquals(LinkPreview.Outcome.Miss(permanent = true), LinkPreview.outcome(LinkPreview.Fetched(200, null)), "상한 초과 본문")
        for (status in listOf(502, 500, 503, 401, 403, 302, 429)) {
            assertEquals(LinkPreview.Outcome.Miss(permanent = false), LinkPreview.outcome(LinkPreview.Fetched(status, ByteArray(0))), "$status")
        }
    }

    @Test fun cacheKeepsHitsAndPermanentMissesAndExpiresTransientMisses() {
        val cache = PreviewCache<String>(maxEntries = 8, missTtlMs = 600_000L)
        assertNull(cache.get("a", 0))
        cache.put("a", LinkPreview.Outcome.Hit("card"), 0)
        cache.put("gone", LinkPreview.Outcome.Miss(permanent = true), 0)
        cache.put("flaky", LinkPreview.Outcome.Miss(permanent = false), 0)
        assertEquals(LinkPreview.Outcome.Hit("card"), cache.get("a", 10_000_000L), "성공은 시간이 지나도 그대로")
        assertEquals(LinkPreview.Outcome.Miss(permanent = true), cache.get("gone", 10_000_000L), "확정 실패는 다시 묻지 않는다")
        assertEquals(LinkPreview.Outcome.Miss(permanent = false), cache.get("flaky", 599_999L), "TTL 안에서는 일시 실패도 다시 묻지 않는다")
        assertNull(cache.get("flaky", 600_000L), "TTL 이 지나면 다시 묻는다")
        assertEquals(2, cache.size)
        cache.clear()
        assertNull(cache.get("a", 0))
    }

    @Test fun cacheEvictsLeastRecentlyUsed() {
        val cache = PreviewCache<Int>(maxEntries = 2)
        cache.put("a", LinkPreview.Outcome.Hit(1), 0)
        cache.put("b", LinkPreview.Outcome.Hit(2), 0)
        assertNotNull(cache.get("a", 1)) // a 를 최근으로
        cache.put("c", LinkPreview.Outcome.Hit(3), 2)
        assertEquals(2, cache.size)
        assertNull(cache.get("b", 3), "가장 오래 안 쓴 b 가 빠진다")
        assertNotNull(cache.get("a", 3))
        assertNotNull(cache.get("c", 3))
    }
}
