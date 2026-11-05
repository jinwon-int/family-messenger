// 미리보기 사이트 v2(#690 계약 v2 클라이언트 절) — 사이트 목록 읽기(정상·깨짐·항목 단위 무시) · 폴백 · 링크 호스트 합집합 · 카드 대상 · 결과 분류 · 음성 캐시.
// android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PreviewSitesTest {
    /** 계약 v2 표 그대로의 릴레이 응답. */
    private val contractJson = """
        {"version":2,"sites":[
          {"id":"x","name":"X","hosts":["x.com","www.x.com","mobile.x.com","twitter.com","www.twitter.com","mobile.twitter.com"],"preview":true},
          {"id":"youtube","name":"YouTube","hosts":["youtube.com","www.youtube.com","m.youtube.com","youtu.be"],"preview":true},
          {"id":"naver-news","name":"네이버 뉴스","hosts":["n.news.naver.com","news.naver.com","m.news.naver.com"],"preview":true},
          {"id":"wikipedia","name":"위키백과","hosts":["ko.wikipedia.org","en.wikipedia.org","ko.m.wikipedia.org","en.m.wikipedia.org"],"preview":true},
          {"id":"github","name":"GitHub","hosts":["github.com","www.github.com"],"preview":true},
          {"id":"bbc","name":"BBC","hosts":["bbc.com","www.bbc.com","bbc.co.uk","www.bbc.co.uk"],"preview":true},
          {"id":"threads","name":"Threads","hosts":["threads.net","www.threads.net","threads.com","www.threads.com"],"preview":false},
          {"id":"reuters","name":"Reuters","hosts":["reuters.com","www.reuters.com"],"preview":false}
        ]}
    """.trimIndent()

    private val v2: PreviewSites.Registry get() = assertNotNull(PreviewSites.parse(contractJson))

    // ---- 읽기 ----

    @Test fun parsesTheContractList() {
        val r = v2
        assertFalse(r.fallback)
        assertEquals(listOf("x", "youtube", "naver-news", "wikipedia", "github", "bbc", "threads", "reuters"), r.sites.map { it.id })
        assertEquals("네이버 뉴스", r.sites[2].name)
        assertEquals(listOf(true, true, true, true, true, true, false, false), r.sites.map { it.preview })
        assertEquals(setOf("youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"), r.sites[1].hosts)
        assertEquals(6 + 4 + 3 + 4 + 2 + 4 + 4 + 2, r.linkHosts.size)
        assertEquals(PreviewSites.parse(contractJson), r, "같은 문서 = 같은 목록(data class — 화면 remember 키)")
    }

    @Test fun badDocumentsAreRejected() {
        for (bad in listOf(
            "",
            "null",
            "[]",
            "\"sites\"",
            "<html>",
            """{"sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true}]}""", // version 없음
            """{"version":1,"sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true}]}""",
            """{"version":3,"sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true}]}""",
            """{"version":"2","sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true}]}""",
            """{"version":2.5,"sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true}]}""",
            """{"version":2}""", // sites 없음
            """{"version":2,"sites":{}}""",
            """{"version":2,"sites":[]}""", // 쓸 수 있는 사이트 없음 → 폴백
            """{"version":2,"sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true},]}""", // 끝 쉼표
            """{"version":2,"version":2,"sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true}]}""", // 같은 키 두 번
            """{"version":2,"sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true}]} x""",
        )) {
            assertNull(PreviewSites.parse(bad), bad)
        }
        val huge = """{"version":2,"sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true}],"pad":"${"a".repeat(PreviewSites.MAX_JSON_BYTES)}"}"""
        assertNull(PreviewSites.parse(huge), "문서 상한")
        val r = assertNotNull(PreviewSites.parse("""{"version":2.0,"extra":{"a":[1]},"sites":[{"id":"x","name":"X","hosts":["x.com"],"preview":true,"more":1}]}"""))
        assertEquals(listOf("x"), r.sites.map { it.id }, "2.0 = 2, 모르는 필드는 무시")
    }

    @Test fun malformedEntriesAreSkippedOneByOne() {
        val json = """
            {"version":2,"sites":[
              {"id":"ok1","name":"First","hosts":["a.example"],"preview":true},
              {"name":"NoId","hosts":["b.example"],"preview":true},
              {"id":"","name":"EmptyId","hosts":["b.example"],"preview":true},
              {"id":"Bad Id","name":"BadId","hosts":["b.example"],"preview":true},
              {"id":"noname","hosts":["b.example"],"preview":true},
              {"id":"blankname","name":"   ","hosts":["b.example"],"preview":true},
              {"id":"numname","name":7,"hosts":["b.example"],"preview":true},
              {"id":"nohosts","name":"N","preview":true},
              {"id":"hostsstr","name":"N","hosts":"b.example","preview":true},
              {"id":"emptyhosts","name":"N","hosts":[],"preview":true},
              {"id":"allbad","name":"N","hosts":["https://b.example","b.example:443","*.b.example","b.example.","localhost",""," b.example","b..example","-b.example","b_c.example","bé.example",7,null],"preview":true},
              {"id":"nopreview","name":"N","hosts":["b.example"]},
              {"id":"strpreview","name":"N","hosts":["b.example"],"preview":"true"},
              {"id":"nullpreview","name":"N","hosts":["b.example"],"preview":null},
              "string entry",
              42,
              null,
              ["array"],
              {"id":"ok1","name":"Duplicate","hosts":["dup.example"],"preview":false},
              {"id":"ok2","name":" Second ","hosts":["C.Example","c.example","bad host","www.c.example"],"preview":false}
            ]}
        """.trimIndent()
        val r = assertNotNull(PreviewSites.parse(json))
        assertEquals(listOf("ok1", "ok2"), r.sites.map { it.id }, "어긋난 항목·앞에서 본 id 는 버린다")
        assertEquals("First", r.sites[0].name)
        assertEquals("Second", r.sites[1].name, "이름 앞뒤 공백 제거")
        assertEquals(setOf("c.example", "www.c.example"), r.sites[1].hosts, "소문자로 바꾸고 중복·잘못된 호스트는 뺀다")
        assertFalse("dup.example" in r.linkHosts)
    }

    @Test fun hostNormalization() {
        assertEquals("www.youtube.com", PreviewSites.normalizeHost("WWW.YouTube.COM"))
        assertEquals("ko.m.wikipedia.org", PreviewSites.normalizeHost("ko.m.wikipedia.org"))
        assertEquals("xn--3e0b707e.example", PreviewSites.normalizeHost("xn--3e0b707e.example"))
        for (bad in listOf("", "x", "x.com:443", "x.com/", "https://x.com", "user@x.com", "*.x.com", "x.com.", ".x.com", "x..com", "-x.com", "x-.com", "x_y.com", "x com", "x.com\n", "서울.example", "a".repeat(64) + ".com")) {
            assertNull(PreviewSites.normalizeHost(bad), bad)
        }
    }

    @Test fun limitsCapSitesAndHosts() {
        val many = (0 until PreviewSites.MAX_SITES + 5).joinToString(",") { """{"id":"s$it","name":"S$it","hosts":["s$it.example"],"preview":false}""" }
        assertEquals(PreviewSites.MAX_SITES, PreviewSites.parse("""{"version":2,"sites":[$many]}""")!!.sites.size)
        val hosts = (0 until PreviewSites.MAX_HOSTS_PER_SITE + 5).joinToString(",") { "\"h$it.example\"" }
        assertEquals(PreviewSites.MAX_HOSTS_PER_SITE, PreviewSites.parse("""{"version":2,"sites":[{"id":"a","name":"A","hosts":[$hosts],"preview":true}]}""")!!.sites[0].hosts.size)
    }

    // ---- 결과 분류(받기 실패 → 폴백) ----

    @Test fun outcomeClassification() {
        val hit = PreviewSites.outcome(LinkPreview.Fetched(200, contractJson.toByteArray()))
        assertTrue(hit is LinkPreview.Outcome.Hit<PreviewSites.Registry> && hit.value.sites.size == 8)
        assertEquals(LinkPreview.Outcome.Miss(permanent = false), PreviewSites.outcome(null), "네트워크 = 일시")
        assertEquals(LinkPreview.Outcome.Miss(permanent = true), PreviewSites.outcome(LinkPreview.Fetched(404, "404 page not found".toByteArray())), "옛 릴레이·플래그 꺼짐")
        assertEquals(LinkPreview.Outcome.Miss(permanent = true), PreviewSites.outcome(LinkPreview.Fetched(200, "<html>".toByteArray())), "읽을 수 없는 200")
        assertEquals(LinkPreview.Outcome.Miss(permanent = true), PreviewSites.outcome(LinkPreview.Fetched(200, null)), "상한 초과 본문")
        assertEquals(LinkPreview.Outcome.Miss(permanent = true), PreviewSites.outcome(LinkPreview.Fetched(200, """{"version":3,"sites":[]}""".toByteArray())), "다른 버전")
        for (status in listOf(502, 500, 503, 401, 403, 302, 429)) {
            assertEquals(LinkPreview.Outcome.Miss(permanent = false), PreviewSites.outcome(LinkPreview.Fetched(status, ByteArray(0))), "$status")
        }
    }

    @Test fun sitesUrlKeepsTheRelayPrefix() {
        assertEquals("https://relay.example/v2/preview/sites", PreviewSites.sitesUrl("https://relay.example/"))
        assertEquals("https://relay.example/hande/v2/preview/sites", PreviewSites.sitesUrl("https://relay.example/hande/"))
        assertEquals("http://10.0.2.2:8080/v2/preview/sites", PreviewSites.sitesUrl("http://10.0.2.2:8080"))
        assertNull(PreviewSites.sitesUrl("ftp://relay.example"))
        assertNull(PreviewSites.sitesUrl("relay.example"))
    }

    // ---- 폴백 = v1 ----

    @Test fun fallbackIsV1Behavior() {
        val f = PreviewSites.FALLBACK
        assertTrue(f.fallback)
        assertEquals(TextLinks.xHosts, f.linkHosts)
        assertEquals(listOf("https://x.com/a/status/1"), f.links("https://youtu.be/dQw4w9WgXcQ https://x.com/a/status/1 https://www.threads.net/@a").map { it.url }, "폴백은 x.com 계열만 링크")
        assertEquals("https://x.com/b/status/9", f.target("https://x.com/home 그리고 https://x.com/b/status/9"), "폴백 카드 = x status 경로 규칙")
        assertNull(f.target("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        assertNull(f.target("https://x.com/jack"))
        assertEquals("X", f.siteOf("https://x.com/a/status/1")?.name)
        // v1 기본 인자 동작은 그대로
        assertEquals(TextLinks.links("https://x.com/a https://github.com/a/b"), f.links("https://x.com/a https://github.com/a/b"))
    }

    // ---- 링크 호스트 합집합 ----

    @Test fun linkUnionIncludesLinkOnlySites() {
        val text = "스레드 https://www.threads.net/@zuck/post/C1 로이터 https://www.reuters.com/world/asia/abc-2026-11-05/ " +
            "유튜브 https://youtu.be/dQw4w9WgXcQ, 깃허브 https://GitHub.com/jinwon-int/family-messenger/issues/690. " +
            "안 됨 https://www.instagram.com/p/A/ https://evil.example/x https://threads.net.evil.example/a http://www.reuters.com/a https://user@github.com/a https://bbc.com:444/a"
        val links = v2.links(text)
        assertEquals(
            listOf(
                "https://www.threads.net/@zuck/post/C1",
                "https://www.reuters.com/world/asia/abc-2026-11-05/",
                "https://youtu.be/dQw4w9WgXcQ",
                "https://GitHub.com/jinwon-int/family-messenger/issues/690",
            ),
            links.map { it.url },
        )
        for (l in links) assertEquals(l.url, text.substring(l.start, l.end))
        for (host in listOf("threads.com", "www.threads.com", "reuters.com", "en.m.wikipedia.org", "www.bbc.co.uk", "m.news.naver.com", "mobile.twitter.com")) {
            assertTrue(host in v2.linkHosts, host)
        }
        assertFalse("www.instagram.com" in v2.linkHosts)
    }

    @Test fun siteOfNamesTheSite() {
        val r = v2
        assertEquals("YouTube", r.siteOf("https://M.YOUTUBE.COM/watch?v=dQw4w9WgXcQ")?.name)
        assertEquals("네이버 뉴스", r.siteOf("https://n.news.naver.com/article/001/0012345678")?.name)
        assertEquals("Reuters", r.siteOf("https://reuters.com/a")?.name)
        assertEquals(false, r.siteOf("https://reuters.com/a")?.preview)
        assertNull(r.siteOf("https://www.instagram.com/p/A/"))
        assertNull(r.siteOf("http://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        assertNull(r.siteOf("https://www.youtube.com:8443/watch?v=dQw4w9WgXcQ"))
        assertNull(r.siteOf("not a url"))
        // 두 사이트가 같은 호스트를 적으면 앞의 것
        val dup = PreviewSites.parse("""{"version":2,"sites":[{"id":"a","name":"A","hosts":["s.example"],"preview":false},{"id":"b","name":"B","hosts":["s.example","t.example"],"preview":true}]}""")!!
        assertEquals("A", dup.siteOf("https://s.example/x")?.name)
        assertNull(dup.target("https://s.example/x"), "앞 사이트가 링크만이면 카드 없음")
        assertEquals("https://t.example/y", dup.target("https://s.example/x https://t.example/y"))
    }

    // ---- 카드 대상 ----

    @Test fun targetIsTheFirstPreviewSiteLinkAsWritten() {
        val r = v2
        val cases = listOf(
            "봐 https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s" to "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
            "https://youtu.be/dQw4w9WgXcQ?si=abc." to "https://youtu.be/dQw4w9WgXcQ?si=abc",
            "https://m.youtube.com/shorts/dQw4w9WgXcQ" to "https://m.youtube.com/shorts/dQw4w9WgXcQ",
            "기사 https://n.news.naver.com/mnews/article/001/0012345678?sid=100 끝" to "https://n.news.naver.com/mnews/article/001/0012345678?sid=100",
            "https://ko.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8" to "https://ko.wikipedia.org/wiki/%EC%84%9C%EC%9A%B8",
            "https://en.m.wikipedia.org/wiki/Seoul?oldid=1" to "https://en.m.wikipedia.org/wiki/Seoul?oldid=1",
            "(https://github.com/jinwon-int/family-messenger/pull/691)" to "https://github.com/jinwon-int/family-messenger/pull/691",
            "https://www.bbc.co.uk/news/articles/c0abcdef123" to "https://www.bbc.co.uk/news/articles/c0abcdef123",
            "https://x.com/jack/status/20" to "https://x.com/jack/status/20",
            // v2 는 경로 판정을 릴레이에 맡긴다 — x 의 첫 링크가 글 링크가 아니어도 그대로 보낸다(400 → 카드 없음, 음성 캐시)
            "https://x.com/home 그리고 https://x.com/b/status/9" to "https://x.com/home",
            // 링크만 사이트는 건너뛴다
            "https://www.threads.net/@a/post/1 https://www.reuters.com/a https://www.bbc.com/news/articles/c0abcdef123" to "https://www.bbc.com/news/articles/c0abcdef123",
            // 허용 밖 링크도 건너뛴다
            "https://www.instagram.com/p/A/ https://evil.example https://github.com/a/b" to "https://github.com/a/b",
            // 첫 preview 링크만
            "https://github.com/a/b https://www.youtube.com/watch?v=dQw4w9WgXcQ" to "https://github.com/a/b",
        )
        for ((text, want) in cases) assertEquals(want, r.target(text), text)
    }

    @Test fun noTargetWithoutPreviewSiteLinks() {
        val r = v2
        for (text in listOf(
            "그냥 글",
            "",
            "https://www.threads.net/@a/post/1",
            "https://www.reuters.com/world/a 그리고 https://threads.com/@b",
            "https://www.instagram.com/p/A/",
            "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://user@github.com/a/b",
            "https://github.com:444/a/b",
            "https://github.com.evil.example/a/b",
            "www.youtube.com/watch?v=dQw4w9WgXcQ",
        )) {
            assertNull(r.target(text), text)
        }
    }

    @Test fun linkOnlyRegistryHasLinksButNoCards() {
        val r = PreviewSites.parse("""{"version":2,"sites":[{"id":"threads","name":"Threads","hosts":["threads.net"],"preview":false}]}""")!!
        assertEquals(listOf("https://threads.net/@a"), r.links("https://threads.net/@a https://x.com/a/status/1").map { it.url }, "목록에 없는 x 는 링크 아님")
        assertNull(r.target("https://threads.net/@a https://x.com/a/status/1"))
    }

    // ---- 음성 캐시(URL 별) ----

    @Test fun negativeCachePerUrl() {
        val cache = PreviewCache<LinkPreview.Card>(maxEntries = 8, missTtlMs = 600_000L)
        val channel = "https://www.youtube.com/@somechannel"
        val video = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        val flaky = "https://www.bbc.com/news/articles/c0abcdef123"
        cache.put(channel, LinkPreview.outcome(LinkPreview.Fetched(400, """{"error":"bad_url"}""".toByteArray())), 0)
        cache.put(video, LinkPreview.outcome(LinkPreview.Fetched(404, """{"error":"no_preview"}""".toByteArray())), 0)
        cache.put(flaky, LinkPreview.outcome(LinkPreview.Fetched(502, """{"error":"upstream_failed"}""".toByteArray())), 0)
        assertEquals(LinkPreview.Outcome.Miss(permanent = true), cache.get(channel, 10_000_000L), "400 은 다시 묻지 않는다")
        assertEquals(LinkPreview.Outcome.Miss(permanent = true), cache.get(video, 10_000_000L), "404 는 다시 묻지 않는다")
        assertEquals(LinkPreview.Outcome.Miss(permanent = false), cache.get(flaky, 599_999L), "502 는 TTL 안에서는 묻지 않는다")
        assertNull(cache.get(flaky, 600_000L), "502 는 TTL 뒤 다시")
        assertNull(cache.get("https://www.youtube.com/watch?v=aaaaaaaaaaa", 0), "다른 URL 은 영향 없음")
        val site = LinkPreview.parse("""{"url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","site":"YouTube","title":"t","description":"","image":null}""")!!
        assertEquals("YouTube", site.site, "응답 site 그대로")
    }
}
