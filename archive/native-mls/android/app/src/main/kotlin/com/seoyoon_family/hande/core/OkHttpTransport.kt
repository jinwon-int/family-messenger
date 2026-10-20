// HOST-CONTRACT §3 `HttpTransport` — 앱 전송(#338 §2 RelayClient). JDK `HttpURLConnection`(`host/JdkHttpTransport`)은 실기기에서
// Cloudflare Access/HTTP2 엣지에 302 응답을 읽을 때 멈췄다(공융 SM-G781N, build fa4f286: 소켓 ESTABLISHED·읽기 타임아웃 미발동).
// OkHttp 는 HTTP/2 협상·`callTimeout` 강제 종료·리다이렉트 무추적을 제대로 한다. 바이트만 옮기는 계약은 같다:
// 응답이 있으면 상태코드 그대로(302·4xx·5xx 포함 — 봉투 해석은 코어), 연결 실패·타임아웃처럼 응답이 없을 때만 throw(→ 코어가 transient).
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.mls.HttpHeader
import com.seoyoon_family.hande.mls.HttpResponse
import com.seoyoon_family.hande.mls.HttpTransport
import com.seoyoon_family.hande.mls.RoomException
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

class OkHttpTransport(
    connectTimeoutSeconds: Long = 10,
    callTimeoutSeconds: Long = 30,
) : HttpTransport {
    private val json = "application/json; charset=utf-8".toMediaType()
    private val client = OkHttpClient.Builder()
        .followRedirects(false)          // CF Access 302 는 "세션 필요" 신호 — 따라가지 않고 코어에 그대로 돌려준다.
        .followSslRedirects(false)
        .retryOnConnectionFailure(true)
        .connectTimeout(connectTimeoutSeconds, TimeUnit.SECONDS)
        .callTimeout(callTimeoutSeconds, TimeUnit.SECONDS) // 전체 호출의 상한 — 반드시 끝난다.
        .build()

    override fun send(method: String, url: String, headers: List<HttpHeader>, body: ByteArray?): HttpResponse {
        val builder = Request.Builder().url(url)
        for (h in headers) builder.addHeader(h.name, h.value)
        builder.method(method, body?.toRequestBody(json))
        return try {
            client.newCall(builder.build()).execute().use { resp ->
                HttpResponse(resp.code.toUShort(), resp.body?.bytes() ?: ByteArray(0))
            }
        } catch (e: IOException) {
            // 응답 없음(연결 거부·리셋·타임아웃): 코어가 `RelayError::Http(Io)` 로 받아 transient 로 분류한다.
            throw RoomException.Host("$method ${url.substringBefore('?')}: ${e.message}")
        }
    }
}
