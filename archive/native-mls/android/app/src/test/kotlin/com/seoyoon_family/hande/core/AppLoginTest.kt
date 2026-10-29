// `AppLogin` 순수 로직 고정(iOS `AppLoginTests` 와 같은 사례). android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`).
package com.seoyoon_family.hande.core

import java.security.SecureRandom
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AppLoginTest {
    private val state = "c3RhdGUtMTIzNDU2Nzg5MC1hYmNkZWZnaGlqa2xtbm9w"
    private val jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJvd25lciJ9.c2ln"

    @Test fun stateIs43Base64urlChars() {
        val s = AppLogin.makeState(SecureRandom())
        assertEquals(43, s.length)
        assertTrue(s.all { it.isLetterOrDigit() || it == '-' || it == '_' }, s)
        assertTrue(AppLogin.makeState() != AppLogin.makeState())
    }

    @Test fun loginUrlJoinsPathAndState() {
        assertEquals("https://relay.example.com/v2/app-login?state=$state", AppLogin.loginUrl("https://relay.example.com", state))
        assertEquals("https://relay.example.com/v2/app-login?state=$state", AppLogin.loginUrl("https://relay.example.com/", state))
        assertEquals("https://relay.example.com/base/v2/app-login?state=$state", AppLogin.loginUrl("https://relay.example.com/base/", state))
        assertEquals("https://relay.example.com/v2/app-login?state=$state", AppLogin.loginUrl("https://relay.example.com?x=1#f", state))
    }

    @Test fun loginUrlRejectsNonHttp() {
        assertNull(AppLogin.loginUrl("hande://auth", state))
        assertNull(AppLogin.loginUrl("relay.example.com", state))
        assertNull(AppLogin.loginUrl("https://", state))
        assertNull(AppLogin.loginUrl("ht tp://x", state))
    }

    @Test fun tokenFromFragment() {
        assertEquals(jwt, AppLogin.tokenFromCallback("hande://auth#jwt=$jwt&state=$state", state))
        assertEquals(jwt, AppLogin.tokenFromCallback("HANDE://Auth#state=$state&jwt=$jwt", state))
    }

    @Test fun queryIsIgnoredOnlyFragmentCounts() {
        assertFailsWith<AppLogin.Failure.StateMismatch> { AppLogin.tokenFromCallback("hande://auth?jwt=$jwt&state=$state", state) }
        assertFailsWith<AppLogin.Failure.StateMismatch> { AppLogin.tokenFromCallback("hande://auth?state=$state#jwt=$jwt", state) }
    }

    @Test fun rejectsForeignCallback() {
        assertFailsWith<AppLogin.Failure.NotCallback> { AppLogin.tokenFromCallback("https://auth#jwt=$jwt&state=$state", state) }
        assertFailsWith<AppLogin.Failure.NotCallback> { AppLogin.tokenFromCallback("hande://other#jwt=$jwt&state=$state", state) }
        assertFailsWith<AppLogin.Failure.NotCallback> { AppLogin.tokenFromCallback("not a url", state) }
    }

    @Test fun rejectsStateMismatchAndEmptyExpected() {
        assertFailsWith<AppLogin.Failure.StateMismatch> { AppLogin.tokenFromCallback("hande://auth#jwt=$jwt&state=other", state) }
        assertFailsWith<AppLogin.Failure.StateMismatch> { AppLogin.tokenFromCallback("hande://auth#jwt=$jwt", state) }
        assertFailsWith<AppLogin.Failure.StateMismatch> { AppLogin.tokenFromCallback("hande://auth#jwt=$jwt&state=", "") }
    }

    @Test fun rejectsMissingOrMalformedToken() {
        assertFailsWith<AppLogin.Failure.MissingToken> { AppLogin.tokenFromCallback("hande://auth#state=$state", state) }
        assertFailsWith<AppLogin.Failure.MissingToken> { AppLogin.tokenFromCallback("hande://auth#jwt=&state=$state", state) }
        assertFailsWith<AppLogin.Failure.MalformedToken> { AppLogin.tokenFromCallback("hande://auth#jwt=a.b&state=$state", state) }
        assertFailsWith<AppLogin.Failure.MalformedToken> { AppLogin.tokenFromCallback("hande://auth#jwt=a.b%2Bc.d&state=$state", state) }
    }

    @Test fun formFieldsKeepsFirstValueAndDecodes() {
        val f = AppLogin.formFields("a=1&a=2&b=%ED%95%9C&c&=x&d=1=2")
        assertEquals("1", f["a"]); assertEquals("한", f["b"]); assertEquals("", f["c"]); assertEquals("1=2", f["d"]); assertNull(f[""])
        assertEquals("a+b", AppLogin.formFields("k=a+b")["k"]) // fragment 는 form 이 아니다 — `+` 는 그대로
    }

    @Test fun jwtShape() {
        assertTrue(AppLogin.isJwtShaped(jwt))
        assertFalse(AppLogin.isJwtShaped("a.b"))
        assertFalse(AppLogin.isJwtShaped("a..c"))
        assertFalse(AppLogin.isJwtShaped("a.b.c.d"))
        assertFalse(AppLogin.isJwtShaped("a.b.c="))
    }

    private fun jwtWith(payload: String) = "eyJhbGciOiJSUzI1NiJ9." + Base64.getUrlEncoder().withoutPadding().encodeToString(payload.toByteArray(Charsets.UTF_8)) + ".c2ln"

    /** 등록 JSON 의 `subject` = JWT payload 의 `sub`(#574 PR 4 버그 수정, iOS `AccessJWT.subject(of:)` 와 같은 규칙). */
    @Test fun subjectOfReadsTheSubClaim() {
        assertEquals("owner", AppLogin.subjectOf(jwt)) // payload {"sub":"owner"}
        assertEquals("owner", AppLogin.subjectOf("  $jwt\n"))
        assertEquals("7c1f3e0a-sub", AppLogin.subjectOf(jwtWith("""{"aud":["x"],"email":"a@b","sub":"7c1f3e0a-sub","iat":1}""")))
        assertEquals("7c1f3e0a-sub", AppLogin.subjectOf(jwtWith("""{ "sub" : "7c1f3e0a-sub" }""")))
        assertEquals("a\"b\\c/d한", AppLogin.subjectOf(jwtWith("""{"sub":"a\"b\\c\/d한"}""")), "JSON escapes are undone")
        // base64url 문자('-'·'_')와 패딩 없는 payload 도 읽는다.
        assertEquals("sub", AppLogin.subjectOf(jwtWith("""{"x":"????>>>","sub":"sub"}""")))
    }

    @Test fun subjectOfIsNullWithoutAUsableSub() {
        assertNull(AppLogin.subjectOf(null))
        assertNull(AppLogin.subjectOf(""))
        assertNull(AppLogin.subjectOf("not a jwt"))
        assertNull(AppLogin.subjectOf("a.b"))
        assertNull(AppLogin.subjectOf("a..c"))
        assertNull(AppLogin.subjectOf("a.%%%.c"), "payload is not base64url")
        assertNull(AppLogin.subjectOf(jwtWith("""{"sub":"","common_name":"bot"}""")), "service token: empty sub")
        assertNull(AppLogin.subjectOf(jwtWith("""{"common_name":"bot"}""")))
        assertNull(AppLogin.subjectOf(jwtWith("""{"sub":42}""")), "sub must be a string")
    }
}
