// HOST-CONTRACT §3 `HttpTransport` — 앱 전송(#338 §2 RelayClient). JDK `HttpURLConnection`(`host/JdkHttpTransport`)은 실기기에서
// Cloudflare Access/HTTP2 엣지에 302 응답을 읽을 때 멈췄다(공융 SM-G781N, build fa4f286: 소켓 ESTABLISHED·읽기 타임아웃 미발동).
// OkHttp 는 HTTP/2 협상·`callTimeout` 강제 종료·리다이렉트 무추적을 제대로 한다. 바이트만 옮기는 계약은 같다:
// 응답이 있으면 상태코드 그대로(302·4xx·5xx 포함 — 봉투 해석은 코어), 연결 실패·타임아웃처럼 응답이 없을 때만 throw(→ 코어가 transient).
//
// 진단(B1.3): 공융에서 OkHttp 로도 첫 호출이 타임아웃 없이 멈춰(build 5436de4) 단계별 로그를 남긴다 — `hande.http` 태그로
// DNS → 연결 → TLS → 요청 → 응답 각 단계의 경과(ms). 어느 줄에서 끊기는지가 곧 멈춘 지점이다. 평문·토큰·본문은 찍지 않는다.
package com.seoyoon_family.hande.core

import android.util.Log
import com.seoyoon_family.hande.mls.HttpHeader
import com.seoyoon_family.hande.mls.HttpResponse
import com.seoyoon_family.hande.mls.HttpTransport
import com.seoyoon_family.hande.mls.RoomException
import okhttp3.Call
import okhttp3.Connection
import okhttp3.EventListener
import okhttp3.Handshake
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

class OkHttpTransport(
    connectTimeoutSeconds: Long = 10,
    readTimeoutSeconds: Long = 15,
    callTimeoutSeconds: Long = 25,
) : HttpTransport {
    private val json = "application/json; charset=utf-8".toMediaType()
    private val seq = AtomicLong()
    private val client = OkHttpClient.Builder()
        .followRedirects(false)          // CF Access 302 는 "세션 필요" 신호 — 따라가지 않고 코어에 그대로 돌려준다.
        .followSslRedirects(false)
        .retryOnConnectionFailure(true)
        .connectTimeout(connectTimeoutSeconds, TimeUnit.SECONDS)
        .readTimeout(readTimeoutSeconds, TimeUnit.SECONDS)
        .writeTimeout(readTimeoutSeconds, TimeUnit.SECONDS)
        .callTimeout(callTimeoutSeconds, TimeUnit.SECONDS) // 전체 호출의 상한 — 반드시 끝난다.
        .eventListenerFactory { call -> PhaseLogger(call.request().tag(String::class.java) ?: "?") }
        .build()

    override fun send(method: String, url: String, headers: List<HttpHeader>, body: ByteArray?): HttpResponse {
        val id = "#${seq.incrementAndGet()}"
        val path = url.substringAfter("://").substringAfter('/').substringBefore('?')
        val builder = Request.Builder().url(url).tag(String::class.java, id)
        for (h in headers) builder.addHeader(h.name, h.value)
        builder.method(method, body?.toRequestBody(json))
        Log.i(TAG, "$id send $method /$path hdr=${headers.size} body=${body?.size ?: 0}")
        val t0 = System.nanoTime()
        return try {
            client.newCall(builder.build()).execute().use { resp ->
                val bytes = resp.body?.bytes() ?: ByteArray(0)
                Log.i(TAG, "$id done ${resp.code} ${resp.protocol} ${bytes.size}B in ${ms(t0)}ms")
                HttpResponse(resp.code.toUShort(), bytes)
            }
        } catch (e: IOException) {
            // 응답 없음(연결 거부·리셋·타임아웃): 코어가 `RelayError::Http(Io)` 로 받아 transient 로 분류한다.
            Log.w(TAG, "$id fail ${e.javaClass.simpleName}: ${e.message} after ${ms(t0)}ms")
            throw RoomException.Host("$method ${url.substringBefore('?')}: ${e.message}")
        } catch (e: RuntimeException) {
            Log.e(TAG, "$id crash ${e.javaClass.simpleName}: ${e.message} after ${ms(t0)}ms", e)
            throw RoomException.Host("$method ${url.substringBefore('?')}: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /** OkHttp 단계 로그 — 끊기는 줄이 멈춘 지점. 주소·프로토콜만, 헤더·본문은 안 찍는다. */
    private class PhaseLogger(private val id: String) : EventListener() {
        private val t0 = System.nanoTime()
        private fun at(what: String) { Log.i(TAG, "$id  +${ms(t0)}ms $what") }
        override fun callStart(call: Call) = at("callStart")
        override fun dnsStart(call: Call, domainName: String) = at("dnsStart $domainName")
        override fun dnsEnd(call: Call, domainName: String, inetAddressList: List<InetAddress>) = at("dnsEnd n=${inetAddressList.size} first=${inetAddressList.firstOrNull()?.hostAddress}")
        override fun connectStart(call: Call, inetSocketAddress: InetSocketAddress, proxy: Proxy) = at("connectStart ${inetSocketAddress.address?.hostAddress}:${inetSocketAddress.port} proxy=${proxy.type()}")
        override fun secureConnectStart(call: Call) = at("secureConnectStart")
        override fun secureConnectEnd(call: Call, handshake: Handshake?) = at("secureConnectEnd ${handshake?.tlsVersion} ${handshake?.cipherSuite}")
        override fun connectEnd(call: Call, inetSocketAddress: InetSocketAddress, proxy: Proxy, protocol: Protocol?) = at("connectEnd $protocol")
        override fun connectFailed(call: Call, inetSocketAddress: InetSocketAddress, proxy: Proxy, protocol: Protocol?, ioe: IOException) = at("connectFailed ${ioe.javaClass.simpleName}: ${ioe.message}")
        override fun connectionAcquired(call: Call, connection: Connection) = at("connectionAcquired ${connection.protocol()} reused=${connection.socket().isConnected}")
        override fun requestHeadersStart(call: Call) = at("requestHeadersStart")
        override fun requestHeadersEnd(call: Call, request: Request) = at("requestHeadersEnd")
        override fun requestBodyEnd(call: Call, byteCount: Long) = at("requestBodyEnd $byteCount")
        override fun responseHeadersStart(call: Call) = at("responseHeadersStart")
        override fun responseHeadersEnd(call: Call, response: Response) = at("responseHeadersEnd ${response.code}")
        override fun responseBodyEnd(call: Call, byteCount: Long) = at("responseBodyEnd $byteCount")
        override fun callEnd(call: Call) = at("callEnd")
        override fun callFailed(call: Call, ioe: IOException) = at("callFailed ${ioe.javaClass.simpleName}: ${ioe.message}")
        override fun canceled(call: Call) = at("canceled")
    }

    private companion object {
        const val TAG = "hande.http"
        fun ms(t0: Long) = (System.nanoTime() - t0) / 1_000_000
    }
}
