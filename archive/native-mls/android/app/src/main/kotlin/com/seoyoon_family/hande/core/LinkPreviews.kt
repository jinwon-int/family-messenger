// 링크 미리보기 로더(#683 2단계) — 판정·캐시 규칙은 `LinkPreview`(순수), 여기는 전송·이미지 디코딩·같은 URL 동시 요청 합치기만.
// 전송은 `OkHttpTransport.getPreview`(코어와 같은 `Cf-Access-Jwt-Assertion` 헤더) — 일반 이미지 로더에 URL 을 넘기지 않는다(계약 v1).
// 이미지는 `BitmapFactory` 로 긴 변 ≤ 1024px 이 되게 줄여 디코딩하고 `ImageBitmap` 으로 메모리 캐시(최대 16장).
// 실패는 전부 조용히 null(카드 없음) — 화면은 링크만 남는다.
package com.seoyoon_family.hande.core

import android.graphics.BitmapFactory
import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

class LinkPreviews(
    private val relayUrl: () -> String?,
    private val accessToken: () -> String?,
    private val http: OkHttpTransport,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val cards = PreviewCache<LinkPreview.Card>(maxEntries = 256)
    private val images = PreviewCache<ImageBitmap>(maxEntries = 16)
    private val inflight = ConcurrentHashMap<String, Deferred<Any?>>()

    private fun now() = SystemClock.elapsedRealtime()

    /** 캐시에 이미 있는 카드(화면을 다시 그릴 때 깜박임 없이). */
    fun cachedCard(link: String): LinkPreview.Card? = (cards.get(link, now()) as? LinkPreview.Outcome.Hit<LinkPreview.Card>)?.value

    fun cachedImage(path: String): ImageBitmap? = (images.get(path, now()) as? LinkPreview.Outcome.Hit<ImageBitmap>)?.value

    /** 카드 — 캐시, 아니면 릴레이에 한 번 묻는다. 없음·실패 = null. */
    suspend fun card(link: String): LinkPreview.Card? {
        when (val c = cards.get(link, now())) {
            is LinkPreview.Outcome.Hit<LinkPreview.Card> -> return c.value
            is LinkPreview.Outcome.Miss -> return null
            null -> Unit
        }
        return once("card:$link") { fetchCard(link) } as? LinkPreview.Card
    }

    /** 카드의 `image`(릴레이 상대 경로) — 같은 인증으로 받아 디코딩. 실패 = null. */
    suspend fun image(path: String): ImageBitmap? {
        when (val c = images.get(path, now())) {
            is LinkPreview.Outcome.Hit<ImageBitmap> -> return c.value
            is LinkPreview.Outcome.Miss -> return null
            null -> Unit
        }
        return once("image:$path") { fetchImage(path) } as? ImageBitmap
    }

    /** 이 기기 지우기(#584) 때 — 세션이 바뀌면 남의 미리보기를 들고 있지 않는다. */
    fun clear() {
        cards.clear()
        images.clear()
    }

    /** 같은 키의 동시 요청은 하나로(여러 말풍선이 같은 링크). 기다리던 화면이 사라져도 요청은 끝까지 가서 캐시에 남는다. */
    private suspend fun once(key: String, work: () -> Any?): Any? {
        val d = inflight.computeIfAbsent(key) { scope.async(start = CoroutineStart.LAZY) { work() } }
        d.start()
        return try { d.await() } finally { inflight.remove(key, d) }
    }

    private fun fetchCard(link: String): LinkPreview.Card? {
        val base = relayUrl() ?: return null // 설정 전 — 캐시하지 않는다
        val url = LinkPreview.previewUrl(base, link) ?: return null
        val outcome = LinkPreview.outcome(get(url, LinkPreview.MAX_JSON_BYTES))
        cards.put(link, outcome, now())
        return (outcome as? LinkPreview.Outcome.Hit<LinkPreview.Card>)?.value
    }

    private fun fetchImage(path: String): ImageBitmap? {
        val base = relayUrl() ?: return null
        val url = LinkPreview.imageUrl(base, path) ?: return null
        val fetched = get(url, LinkPreview.MAX_IMAGE_BYTES)
        val outcome: LinkPreview.Outcome<ImageBitmap> = when {
            fetched == null -> LinkPreview.Outcome.Miss(permanent = false)
            fetched.status != 200 -> LinkPreview.Outcome.Miss(permanent = fetched.status == 400 || fetched.status == 404)
            else -> fetched.body?.let(::decode)?.let { LinkPreview.Outcome.Hit(it) } ?: LinkPreview.Outcome.Miss(permanent = true)
        }
        images.put(path, outcome, now())
        return (outcome as? LinkPreview.Outcome.Hit<ImageBitmap>)?.value
    }

    /** 응답 없음(연결 실패·타임아웃·잘못된 주소/헤더) = null. */
    private fun get(url: String, maxBytes: Int): LinkPreview.Fetched? = try {
        http.getPreview(url, accessToken(), maxBytes)
    } catch (e: IOException) {
        Log.w(TAG, "preview fetch failed: ${e.javaClass.simpleName}")
        null
    } catch (e: IllegalArgumentException) {
        Log.w(TAG, "preview fetch rejected: ${e.javaClass.simpleName}")
        null
    }

    private fun decode(bytes: ByteArray): ImageBitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            null
        } else {
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_IMAGE_SIDE) sample *= 2
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)?.asImageBitmap()
        }
    } catch (e: RuntimeException) {
        Log.w(TAG, "preview image decode failed: ${e.javaClass.simpleName}")
        null
    } catch (e: OutOfMemoryError) {
        Log.w(TAG, "preview image too large to decode")
        null
    }

    private companion object {
        const val TAG = "hande.preview"
        const val MAX_IMAGE_SIDE = 1024
    }
}
