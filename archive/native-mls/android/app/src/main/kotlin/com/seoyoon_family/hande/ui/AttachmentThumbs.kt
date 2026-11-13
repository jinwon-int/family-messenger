// 말풍선 사진 썸네일(#698 C2): 화면에 보이는 첨부 행만(LazyColumn 이 그린 항목의 `LaunchedEffect`) 바이트를 얻어 긴 변 360dp × density 로
// 디코드하고, 결과 비트맵은 **프로세스 메모리 LRU 에만** 둔다 — 복호화한 바이트·썸네일을 디스크에 쓰지 않는다(FILE-V2 §4-2).
// 바이트는 `DeviceHub.openAttachment`(v1 = 이력의 바이트, file-v2 = blob 받기·검증·복호 — 허브 mutex 밖). 크기 규칙은 `core/ThumbnailSizing`.
package com.seoyoon_family.hande.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.os.Build
import android.util.Log
import android.util.LruCache
import com.seoyoon_family.hande.core.AttachmentFiles
import com.seoyoon_family.hande.core.ThumbnailSizing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.IOException
import java.nio.ByteBuffer

/** 한 첨부 행의 썸네일 입력: [key] = 방·seq, [preview] = 시도할지·자리 힌트(이력만 읽음), [open] = 바이트 얻기(필요할 때만). */
class ThumbSource(
    val key: String,
    val preview: suspend () -> ThumbnailSizing.Preview?,
    val open: suspend () -> AttachmentFiles.OpenResult,
)

object AttachmentThumbs {
    private const val TAG = "hande.thumb"
    /** 동시에 받는·디코드하는 첨부 수 — 빠르게 넘겨도 큰 blob 을 한꺼번에 받지 않게. */
    private val gate = Semaphore(2)
    /** 비트맵 LRU(바이트 단위): 힙의 1/8, 최대 48 MiB. */
    private val bitmaps = object : LruCache<String, Bitmap>(cacheBytes()) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }
    /** 사진이 아니거나 그릴 수 없는 첨부(다시 받지 않는다). 전송 실패처럼 다시 해 볼 만한 실패는 적지 않는다. */
    private val notImage = LruCache<String, Boolean>(512)
    /** 시도할지·자리 힌트(이력 읽기 결과) — 다시 보일 때 자리를 바로 잡게. */
    private val previews = LruCache<String, ThumbnailSizing.Preview>(512)

    private fun cacheBytes(): Int = minOf(Runtime.getRuntime().maxMemory() / 8, 48L * 1024 * 1024).toInt().coerceAtLeast(4 * 1024 * 1024)

    fun cached(key: String): Bitmap? = bitmaps.get(key)
    fun cachedPreview(key: String): ThumbnailSizing.Preview? = previews.get(key)
    fun knownNotImage(key: String): Boolean = notImage.get(key) != null

    /** 이 기기 지우기 뒤: 메모리의 썸네일도 버린다. */
    fun clear() {
        bitmaps.evictAll()
        notImage.evictAll()
        previews.evictAll()
    }

    /** 시도할지·자리 힌트. 이력에 없으면 null. */
    suspend fun preview(source: ThumbSource): ThumbnailSizing.Preview? {
        previews.get(source.key)?.let { return it }
        val p = source.preview() ?: return null
        previews.put(source.key, p)
        if (!p.candidate) notImage.put(source.key, true)
        return p
    }

    /**
     * 썸네일 비트맵(긴 변 ≤ [targetLongPx]) 또는 null(사진 아님 · 디코드 실패 · 받기 실패). 받은 바이트의 내용 판별이 `image` 일 때만
     * 디코드한다. 바이트는 이 함수 안에서만 쓰고 버린다.
     */
    suspend fun load(source: ThumbSource, targetLongPx: Int): Bitmap? {
        bitmaps.get(source.key)?.let { return it }
        if (knownNotImage(source.key)) return null
        return gate.withPermit {
            bitmaps.get(source.key)?.let { return@withPermit it }
            // 받기·복호(최대 20 MiB × 동시 2)도 메모리가 크다 — 썸네일 실패가 앱을 죽이지 않게 OOM·예외를 여기서 삼킨다(탭하면 뷰어로는 열린다).
            val opened = try {
                source.open()
            } catch (e: OutOfMemoryError) {
                Log.w(TAG, "thumbnail open out of memory")
                notImage.put(source.key, true)
                return@withPermit null
            } catch (e: CancellationException) {
                throw e // 행이 화면을 벗어나 취소된 것 — 삼키지 않는다
            } catch (e: RuntimeException) {
                Log.w(TAG, "thumbnail open failed: ${e.javaClass.simpleName}")
                return@withPermit null
            }
            when (val r = opened) {
                is AttachmentFiles.Opened -> {
                    val bmp = if (r.kind == "image") withContext(Dispatchers.Default) { decode(r.bytes, targetLongPx) } else null
                    if (bmp == null) notImage.put(source.key, true) else bitmaps.put(source.key, bmp)
                    bmp
                }
                is AttachmentFiles.OpenFailed -> {
                    if (!r.retry) notImage.put(source.key, true)
                    null
                }
            }
        }
    }

    /**
     * 긴 변 [target] px 로 디코드: API 28+ 는 `ImageDecoder`(EXIF 방향 반영) + 표본 크기, 26~27 은 `BitmapFactory` + `inSampleSize`.
     * 표본 디코드가 목표보다 크면 한 번 더 줄인다(LRU 에 큰 비트맵을 두지 않게). 실패는 null.
     */
    private fun decode(bytes: ByteArray, target: Int): Bitmap? {
        return try {
            val decoded = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    decoder.setTargetSampleSize(ThumbnailSizing.sampleSize(info.size.width, info.size.height, target))
                }
            } else {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
                val options = BitmapFactory.Options().apply { inSampleSize = ThumbnailSizing.sampleSize(bounds.outWidth, bounds.outHeight, target) }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
            }
            val (w, h) = ThumbnailSizing.scaledSize(decoded.width, decoded.height, target)
            if (w == decoded.width && h == decoded.height) {
                decoded
            } else {
                val scaled = Bitmap.createScaledBitmap(decoded, w, h, true)
                if (scaled !== decoded) decoded.recycle()
                scaled
            }
        } catch (e: IOException) {
            Log.w(TAG, "thumbnail decode failed: ${e.javaClass.simpleName}")
            null
        } catch (e: RuntimeException) {
            Log.w(TAG, "thumbnail decode failed: ${e.javaClass.simpleName}")
            null
        } catch (e: OutOfMemoryError) {
            Log.w(TAG, "thumbnail decode out of memory")
            null
        }
    }
}
