// 첨부 열기·보내기의 Android 쪽 입출력(#366 C · #338 C 단계): 선택한 파일 읽기 · 임시 공유 파일(FileProvider) · 이미지 디코딩.
// 복호화한 첨부 바이트는 이력(`messages.db`)에 저장하지 않는다(FILE-V2 §4-2) — 열 때마다 다시 받고, 공유를 위해 앱 cache 의
// `attachments/` 에만 잠깐 둔다. 그 디렉터리는 허브가 시작할 때 비운다(`clearShared`). 규칙(이름·확장자·크기)은 `core/AttachmentFiles`.
package com.seoyoon_family.hande.ui

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.content.FileProvider
import com.seoyoon_family.hande.core.AttachmentFiles
import com.seoyoon_family.hande.core.AttachmentFiles.Opened
import java.io.File
import java.io.IOException

object AttachmentIo {
    private const val TAG = "hande.attach"
    private const val SHARED_DIR = "attachments"
    /** 뷰어 이미지의 긴 변(px) — 큰 사진도 메모리를 넘지 않게 줄여 디코딩한다(원본은 공유로). */
    private const val MAX_VIEW_SIDE = 2048

    /** 고른 파일을 읽은 결과. */
    sealed interface Picked {
        class Ok(val bytes: ByteArray, val name: String?) : Picked
        data object Empty : Picked
        data object TooLarge : Picked
        data object Unreadable : Picked
    }

    /** 허브가 시작할 때(프로세스 하나에 한 번): 지난 실행이 남긴 임시 공유 파일을 지운다. */
    fun clearShared(context: Context) {
        File(context.cacheDir, SHARED_DIR).deleteRecursively()
    }

    /** `OpenDocument` 로 고른 파일을 읽는다(크기 상한 50 MiB — 넘으면 읽지 않는다). IO 스레드에서 부른다. */
    fun readPicked(context: Context, uri: Uri): Picked {
        val resolver = context.contentResolver
        var name: String? = null
        var size: Long? = null
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val s = c.getColumnIndex(OpenableColumns.SIZE)
                    if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                    if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
                }
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "picked file metadata unavailable: ${e.javaClass.simpleName}")
        }
        when (AttachmentFiles.checkSize(size)) {
            AttachmentFiles.SizeCheck.EMPTY -> return Picked.Empty
            AttachmentFiles.SizeCheck.TOO_LARGE -> return Picked.TooLarge
            else -> {}
        }
        return try {
            val input = resolver.openInputStream(uri) ?: return Picked.Unreadable
            // 크기를 모르거나 제공자가 틀렸어도 상한 + 1 바이트까지만 읽는다.
            val bytes = input.use { it.readNBytesCompat(AttachmentFiles.MAX_SEND_BYTES + 1) }
            when (AttachmentFiles.checkSize(bytes.size.toLong())) {
                AttachmentFiles.SizeCheck.EMPTY -> Picked.Empty
                AttachmentFiles.SizeCheck.TOO_LARGE -> Picked.TooLarge
                else -> Picked.Ok(bytes, name)
            }
        } catch (e: IOException) {
            Log.w(TAG, "picked file unreadable: ${e.javaClass.simpleName}")
            Picked.Unreadable
        } catch (e: SecurityException) {
            Log.w(TAG, "picked file not permitted: ${e.javaClass.simpleName}")
            Picked.Unreadable
        }
    }

    /** `InputStream.readNBytes` 는 API 33+ — minSdk 26 이라 직접 읽는다. */
    private fun java.io.InputStream.readNBytesCompat(limit: Long): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(64 * 1024)
        var total = 0L
        while (total < limit) {
            val n = read(buf, 0, minOf(buf.size.toLong(), limit - total).toInt())
            if (n < 0) break
            out.write(buf, 0, n)
            total += n
        }
        return out.toByteArray()
    }

    /** 뷰어용 디코딩(긴 변 ≤ 2048px). 디코딩할 수 없는 이미지(형식·손상)는 null — 호출자가 「다른 앱으로 열기」로 넘긴다. */
    fun decodeImage(bytes: ByteArray): ImageBitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            null
        } else {
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_VIEW_SIDE) sample *= 2
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
        }
    } catch (e: RuntimeException) {
        Log.w(TAG, "image decode failed: ${e.javaClass.simpleName}")
        null
    } catch (e: OutOfMemoryError) {
        Log.w(TAG, "image decode out of memory")
        null
    }

    /** 임시 공유 파일 → content:// URI(`<패키지>.files` FileProvider, cache `attachments/`). 호출마다 새 하위 디렉터리(이름 충돌 없음). */
    private fun sharedUri(context: Context, opened: Opened): Uri {
        val dir = File(context.cacheDir, "$SHARED_DIR/${System.nanoTime()}").apply { mkdirs() }
        val file = File(dir, opened.name).apply { writeBytes(opened.bytes) }
        return FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    }

    /** 다른 앱으로 열기(ACTION_VIEW, 읽기 권한만 잠깐 준다). 받을 앱이 없으면 공유 시트로. */
    fun openWith(context: Context, opened: Opened, title: String) {
        val uri = sharedUri(context, opened)
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, opened.mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            context.startActivity(Intent.createChooser(view, title).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: ActivityNotFoundException) {
            share(context, opened, title, uri)
        }
    }

    /** 공유 시트(ACTION_SEND + EXTRA_STREAM). 받을 앱이 없으면 아무것도 하지 않고 거짓. */
    fun share(context: Context, opened: Opened, title: String, existing: Uri? = null): Boolean {
        val uri = existing ?: sharedUri(context, opened)
        val send = Intent(Intent.ACTION_SEND).setType(opened.mime).putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData.newRawUri(opened.name, uri)
        return try {
            context.startActivity(Intent.createChooser(send, title).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }
}
