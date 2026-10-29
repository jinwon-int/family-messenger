// `ServerDiscovery` 순수 로직 고정(#584 PR 3 — 릴레이 `server/wellknown_test.go` 와 같은 문서). android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`).
// 전송은 가짜 `fetch`(주소 → 상태·본문 표) — 후보 순서, 정규화, 문서 검증/거부, 문서 없을 때 입력값 폴백, `/v2/health` 확인, 「앱이 오래됨」.
package com.seoyoon_family.hande.core

import kotlinx.coroutines.runBlocking
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ServerDiscoveryTest {
    private val wk = "/.well-known/hande"
    private val doc = """{"version":1,"relay":{"base_url":"https://relay.example","app_login":"/v2/app-login"},"hande":{"web_url":"https://hande.example"},"name":"서윤 가족","min_app":{"ios":"0.1.0","android":"0.1.0"}}"""
    private val ok = """{"ok":true}"""

    /** 가짜 전송: 표에 없는 주소는 연결 실패(throw). 불린 주소를 순서대로 적어 둔다. */
    private class Fake(private val table: Map<String, ServerDiscovery.Fetched>) {
        val calls = ArrayList<String>()
        suspend fun fetch(url: String): ServerDiscovery.Fetched {
            calls += url
            return table[url] ?: throw IOException("connect refused: $url")
        }
    }

    private fun discover(input: String, version: String = "0.1.0", vararg routes: Pair<String, ServerDiscovery.Fetched>): Pair<ServerDiscovery.Result, List<String>> {
        val fake = Fake(routes.toMap())
        val r = runBlocking { ServerDiscovery.discover(input, version, fake::fetch) }
        return r to fake.calls
    }

    private fun resp(status: Int, body: String) = ServerDiscovery.Fetched(status, body)

    // ---- 정규화 ----

    @Test fun normalizeAddsHttpsLowercasesHostAndTrimsSlash() {
        assertEquals("https://family.example", ServerDiscovery.normalizeBase("family.example"))
        assertEquals("https://family.example", ServerDiscovery.normalizeBase("  Family.Example/  "))
        assertEquals("https://family.example", ServerDiscovery.normalizeBase("HTTPS://Family.EXAMPLE///"))
        assertEquals("https://relay.example:8443/base", ServerDiscovery.normalizeBase("https://relay.example:8443/base/"))
        assertEquals("https://relay.example", ServerDiscovery.normalizeBase("https://relay.example?x=1#f"), "query/fragment dropped")
        assertEquals("https://relay.example", ServerDiscovery.normalizeBase("relay.example."), "trailing dot trimmed")
    }

    @Test fun normalizeAllowsHttpOnlyForLocalhost() {
        assertEquals("http://localhost:8080", ServerDiscovery.normalizeBase("http://localhost:8080/"))
        assertEquals("http://127.0.0.1:8080", ServerDiscovery.normalizeBase("http://127.0.0.1:8080"))
        assertNull(ServerDiscovery.normalizeBase("http://relay.example"))
        assertNull(ServerDiscovery.normalizeBase("http://10.0.0.5:8080"))
    }

    @Test fun normalizeRejectsGarbage() {
        assertNull(ServerDiscovery.normalizeBase(""))
        assertNull(ServerDiscovery.normalizeBase("   "))
        assertNull(ServerDiscovery.normalizeBase("https://"))
        assertNull(ServerDiscovery.normalizeBase("ht tp://x"))
        assertNull(ServerDiscovery.normalizeBase("hande://auth"))
        assertNull(ServerDiscovery.normalizeBase("ftp://relay.example"))
        assertNull(ServerDiscovery.normalizeBase("https://user:pw@relay.example"), "userinfo")
        assertNull(ServerDiscovery.normalizeBase("https://relay.example/a//b"), "empty path segment")
        assertNull(ServerDiscovery.normalizeBase("https://relay.example/a/../b"), "dot-dot")
        assertNull(ServerDiscovery.normalizeBase("https://relay.example:abc"))
    }

    // ---- 후보 순서 ----

    @Test fun candidatesHostThenHandePrefix() {
        assertEquals(listOf("https://family.example$wk", "https://hande.family.example$wk"), ServerDiscovery.candidates("family.example"))
        assertEquals(listOf("https://family.example$wk", "https://hande.family.example$wk"), ServerDiscovery.candidates("HTTPS://Family.Example/some/path/"), "path ignored — well-known lives at the root")
        assertEquals(listOf("https://relay.example:8443$wk", "https://hande.relay.example:8443$wk"), ServerDiscovery.candidates("relay.example:8443"))
    }

    @Test fun candidatesSkipHandePrefixWhenPointless() {
        assertEquals(listOf("https://hande.family.example$wk"), ServerDiscovery.candidates("hande.family.example"))
        assertEquals(listOf("http://localhost:8080$wk"), ServerDiscovery.candidates("http://localhost:8080"))
        assertEquals(listOf("https://10.0.0.5$wk"), ServerDiscovery.candidates("https://10.0.0.5"))
        assertEquals(emptyList(), ServerDiscovery.candidates("http://relay.example"))
        assertEquals(emptyList(), ServerDiscovery.candidates(""))
    }

    // ---- 문서 검증 ----

    @Test fun parsesFullDocument() {
        val d = assertNotNull(ServerDiscovery.parseWellKnown(doc))
        assertEquals("https://relay.example", d.baseUrl)
        assertEquals("/v2/app-login", d.appLogin)
        assertEquals("https://hande.example", d.webUrl)
        assertEquals("서윤 가족", d.name)
        assertEquals("0.1.0", d.minIos)
        assertEquals("0.1.0", d.minAndroid)
    }

    @Test fun parsesMinimalDocumentAndNormalizesBase() {
        val d = assertNotNull(ServerDiscovery.parseWellKnown(""" {"version":1,"relay":{"base_url":"HTTPS://Relay.Example:8443/base/"}} """))
        assertEquals("https://relay.example:8443/base", d.baseUrl)
        assertEquals("/v2/app-login", d.appLogin, "app_login defaults to the fixed path")
        assertNull(d.webUrl); assertNull(d.name); assertNull(d.minIos); assertNull(d.minAndroid)
        // 모르는 키 · JSON null · 한쪽만 있는 min_app 은 괜찮다(앞으로의 version 1 추가 필드).
        val e = assertNotNull(ServerDiscovery.parseWellKnown("""{"version":1,"relay":{"base_url":"https://r.example","extra":1},"name":null,"hande":null,"min_app":{"android":"1.2"},"future":{"x":[1,2]}}"""))
        assertNull(e.name); assertNull(e.minIos); assertEquals("1.2", e.minAndroid)
        assertEquals("http://localhost:8080", assertNotNull(ServerDiscovery.parseWellKnown("""{"version":1,"relay":{"base_url":"http://localhost:8080"}}""")).baseUrl)
    }

    @Test fun nameIsSanitizedNotRejected() {
        assertEquals("ab", assertNotNull(ServerDiscovery.parseWellKnown("""{"version":1,"relay":{"base_url":"https://r.example"},"name":" a\tb\n "}""")).name, "control characters dropped, trimmed")
        assertNull(assertNotNull(ServerDiscovery.parseWellKnown("""{"version":1,"relay":{"base_url":"https://r.example"},"name":"  "}""")).name)
        assertEquals(64, assertNotNull(ServerDiscovery.parseWellKnown("""{"version":1,"relay":{"base_url":"https://r.example"},"name":"${"가".repeat(80)}"}""")).name?.length)
    }

    @Test fun rejectsBadDocuments() {
        val base = """"relay":{"base_url":"https://r.example"}"""
        for (bad in listOf(
            "", "not json", "[]", "null", """{"version":1}""",
            """{"version":2,$base}""", """{"version":"1",$base}""", """{"version":1.5,$base}""", """{$base}""",
            """{"version":1,"relay":{"base_url":"http://r.example"}}""", // http (not localhost)
            """{"version":1,"relay":{"base_url":"r.example"}}""", // no scheme — only user input may omit it
            """{"version":1,"relay":{"base_url":"https://u:p@r.example"}}""",
            """{"version":1,"relay":{"base_url":42}}""", """{"version":1,"relay":"https://r.example"}""",
            """{"version":1,"relay":{"base_url":"https://r.example","app_login":"v2/app-login"}}""",
            """{"version":1,"relay":{"base_url":"https://r.example","app_login":7}}""",
            """{"version":1,$base,"hande":{"web_url":"hande.example"}}""", """{"version":1,$base,"hande":"x"}""",
            """{"version":1,$base,"name":7}""",
            """{"version":1,$base,"min_app":{"android":"latest"}}""", """{"version":1,$base,"min_app":{"android":1}}""", """{"version":1,$base,"min_app":[]}""",
            """{"version":1,"version":1,$base}""", // duplicate key (StrictJson)
            "<!doctype html><title>hande</title>",
        )) assertNull(ServerDiscovery.parseWellKnown(bad), bad)
        assertNull(ServerDiscovery.parseWellKnown("""{"version":1,$base,"pad":"${"x".repeat(ServerDiscovery.MAX_DOC_BYTES)}"}"""), "oversized")
    }

    // ---- 버전 비교 ----

    @Test fun compareVersionsIsLooseSemver() {
        assertEquals(0, ServerDiscovery.compareVersions("0.1.0", "0.1"))
        assertEquals(0, ServerDiscovery.compareVersions("1", "1.0.0"))
        assertTrue(ServerDiscovery.compareVersions("0.1.0", "0.2") < 0)
        assertTrue(ServerDiscovery.compareVersions("0.10.0", "0.9.9") > 0, "numeric, not lexical")
        assertTrue(ServerDiscovery.compareVersions("1.0.0", "0.99.99") > 0)
        assertEquals(0, ServerDiscovery.compareVersions("0.1.0-beta+7", "0.1.0"), "pre-release/build ignored")
        assertTrue(ServerDiscovery.compareVersions("abc", "0.0.1") < 0, "garbage counts as 0")
    }

    @Test fun healthBodyShape() {
        assertTrue(ServerDiscovery.healthOk(ok))
        assertTrue(ServerDiscovery.healthOk("""{"ok":true,"version":"x"}"""))
        assertFalse(ServerDiscovery.healthOk("""{"ok":false}"""))
        assertFalse(ServerDiscovery.healthOk("""{"ok":"true"}"""))
        assertFalse(ServerDiscovery.healthOk("ok"))
        assertFalse(ServerDiscovery.healthOk(""))
    }

    // ---- 탐색 전체 ----

    @Test fun domainOnlyFindsRelayViaFirstCandidate() {
        val (r, calls) = discover("Family.Example", "0.1.0", "https://family.example$wk" to resp(200, doc), "https://relay.example/v2/health" to resp(200, ok))
        val f = assertIs<ServerDiscovery.Result.Found>(r)
        assertEquals("https://relay.example", f.baseUrl)
        assertEquals("서윤 가족", f.name)
        assertNotNull(f.wellKnown)
        assertTrue(f.healthOk)
        assertEquals(listOf("https://family.example$wk", "https://relay.example/v2/health"), calls, "second candidate not tried")
    }

    @Test fun fallsThroughToHandeHostWhenApexIsNotADocument() {
        val (r, calls) = discover(
            "family.example", "0.1.0",
            "https://family.example$wk" to resp(200, "<!doctype html><title>family</title>"), // 아무 경로에나 index 를 주는 웹 호스트
            "https://hande.family.example$wk" to resp(200, doc),
            "https://relay.example/v2/health" to resp(200, ok),
        )
        assertEquals("https://relay.example", assertIs<ServerDiscovery.Result.Found>(r).baseUrl)
        assertEquals(listOf("https://family.example$wk", "https://hande.family.example$wk", "https://relay.example/v2/health"), calls)
    }

    @Test fun noDocumentUsesInputAsRelayBase() {
        // 둘 다 404 → 입력값(정규형)이 릴레이. 연결 실패(throw)도 같은 뜻이다.
        val (r, calls) = discover("https://Relay.Example/", "0.1.0", "https://relay.example$wk" to resp(404, "{}"), "https://relay.example/v2/health" to resp(200, ok))
        val f = assertIs<ServerDiscovery.Result.Found>(r)
        assertEquals("https://relay.example", f.baseUrl)
        assertNull(f.name); assertNull(f.wellKnown); assertTrue(f.healthOk)
        assertEquals(listOf("https://relay.example$wk", "https://hande.relay.example$wk", "https://relay.example/v2/health"), calls)
        // 문서 응답이 302(엣지가 well-known 을 가림) 여도 문서 없음으로 본다.
        val (r2, _) = discover("relay.example", "0.1.0", "https://relay.example$wk" to resp(302, ""), "https://relay.example/v2/health" to resp(200, ok))
        assertNull(assertIs<ServerDiscovery.Result.Found>(r2).wellKnown)
    }

    @Test fun healthMustAnswerOk() {
        val (r1, _) = discover("relay.example", "0.1.0", "https://relay.example/v2/health" to resp(200, "<html>"))
        assertEquals(ServerDiscovery.Result.Unreachable("https://relay.example", "status 200"), r1)
        val (r2, _) = discover("relay.example", "0.1.0", "https://relay.example/v2/health" to resp(404, ""))
        assertEquals(ServerDiscovery.Result.Unreachable("https://relay.example", "status 404"), r2)
        val (r3, _) = discover("relay.example", "0.1.0", "https://relay.example/v2/health" to resp(200, """{"ok":false}"""))
        assertIs<ServerDiscovery.Result.Unreachable>(r3)
        val (r4, _) = discover("relay.example", "0.1.0")
        val u = assertIs<ServerDiscovery.Result.Unreachable>(r4)
        assertEquals("https://relay.example", u.baseUrl)
        assertTrue("connect refused" in u.detail, u.detail)
    }

    @Test fun edgeGatedHealthStillCountsAsFound() {
        // 가족 릴레이는 CF Access 뒤 — health 가 302/401/403 이면 릴레이가 그 뒤에 있는 것(저장 뒤 로그인). healthOk=false 로 알린다.
        for (status in listOf(302, 401, 403)) {
            val (r, _) = discover("family.example", "0.1.0", "https://family.example$wk" to resp(200, doc), "https://relay.example/v2/health" to resp(status, ""))
            val f = assertIs<ServerDiscovery.Result.Found>(r, "status $status")
            assertFalse(f.healthOk); assertEquals("서윤 가족", f.name)
        }
    }

    @Test fun tooOldAppIsRefusedBeforeHealth() {
        val (r, calls) = discover("family.example", "0.0.9", "https://family.example$wk" to resp(200, doc), "https://relay.example/v2/health" to resp(200, ok))
        assertEquals(ServerDiscovery.Result.TooOld("https://relay.example", "서윤 가족", "0.1.0", "0.0.9"), r)
        assertEquals(listOf("https://family.example$wk"), calls, "health not probed")
        // 같은 버전·더 높은 버전·min_app 없음은 통과.
        assertIs<ServerDiscovery.Result.Found>(discover("family.example", "0.1.0", "https://family.example$wk" to resp(200, doc), "https://relay.example/v2/health" to resp(200, ok)).first)
        assertIs<ServerDiscovery.Result.Found>(discover("family.example", "1.0", "https://family.example$wk" to resp(200, doc), "https://relay.example/v2/health" to resp(200, ok)).first)
        val noMin = """{"version":1,"relay":{"base_url":"https://relay.example"}}"""
        assertIs<ServerDiscovery.Result.Found>(discover("family.example", "0", "https://family.example$wk" to resp(200, noMin), "https://relay.example/v2/health" to resp(200, ok)).first)
    }

    @Test fun badInputStopsBeforeAnyFetch() {
        for (input in listOf("", "http://relay.example", "https://u:p@relay.example", "ht tp://x")) {
            val (r, calls) = discover(input, "0.1.0", "https://relay.example/v2/health" to resp(200, ok))
            assertEquals(ServerDiscovery.Result.BadInput, r, input)
            assertTrue(calls.isEmpty(), input)
        }
    }

    @Test fun localhostDevRelayOverHttp() {
        val (r, calls) = discover("http://localhost:8080/", "0.1.0", "http://localhost:8080$wk" to resp(404, ""), "http://localhost:8080/v2/health" to resp(200, ok))
        assertEquals("http://localhost:8080", assertIs<ServerDiscovery.Result.Found>(r).baseUrl)
        assertEquals(listOf("http://localhost:8080$wk", "http://localhost:8080/v2/health"), calls)
    }
}
