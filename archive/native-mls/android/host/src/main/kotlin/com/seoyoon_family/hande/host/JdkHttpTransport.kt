// HOST-CONTRACT §3 `HttpTransport` — JDK `HttpURLConnection`(Android 에도 있다; 앱은 OkHttp 로 바꿔도 같은 규칙).
// 바이트만 옮긴다: 응답이 있으면 상태코드가 무엇이든 그대로, 연결 실패·타임아웃처럼 응답이 없을 때만 throw(→ 코어가 transient).
package com.seoyoon_family.hande.host

import com.seoyoon_family.hande.mls.HttpHeader
import com.seoyoon_family.hande.mls.HttpResponse
import com.seoyoon_family.hande.mls.HttpTransport
import com.seoyoon_family.hande.mls.RoomException
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

class JdkHttpTransport(
    private val connectTimeoutMs: Int = 10_000,
    private val readTimeoutMs: Int = 120_000,
) : HttpTransport {
    override fun send(method: String, url: String, headers: List<HttpHeader>, body: ByteArray?): HttpResponse {
        val conn = try {
            URL(url).openConnection() as HttpURLConnection
        } catch (e: IOException) {
            throw RoomException.Host("open ${url.substringBefore('?')}: ${e.message}")
        }
        try {
            conn.requestMethod = method
            conn.connectTimeout = connectTimeoutMs
            conn.readTimeout = readTimeoutMs
            conn.instanceFollowRedirects = false
            conn.useCaches = false
            for (h in headers) conn.setRequestProperty(h.name, h.value)
            if (body != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.outputStream.use { it.write(body) }
            }
            val status = conn.responseCode
            val stream = if (status >= 400) conn.errorStream else conn.inputStream
            val bytes = stream?.use { it.readBytes() } ?: ByteArray(0)
            return HttpResponse(status.toUShort(), bytes)
        } catch (e: IOException) {
            // 응답 없음(연결 거부·리셋·타임아웃): 코어가 `RelayError::Http(Io)` 로 받아 transient 로 분류한다.
            throw RoomException.Host("$method ${url.substringBefore('?')}: ${e.message}")
        } finally {
            conn.disconnect()
        }
    }
}
