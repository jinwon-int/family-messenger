// 받은 PDF 를 앱 안에서 보기(#698 C3): `android.graphics.pdf.PdfRenderer`(시스템 PDFium, 외부 앱·네트워크 없음).
// 복호화한 바이트를 앱 전용 cache `hande-open/` 에만 잠깐 파일로 두고(PdfRenderer 는 파일 기술자만 연다) 뷰어를 닫으면 지운다 —
// 남은 것은 허브 시작 때 `AttachmentIo.clearShared` 가 지운다. 평문이 다른 앱으로 가는 것은 사용자가 「공유」·「다른 앱으로 열기」를 누를 때뿐.
// 크기·쪽 표시 규칙은 `core/PdfPages`.
package com.seoyoon_family.hande.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.seoyoon_family.hande.core.AttachmentFiles
import com.seoyoon_family.hande.core.PdfPages
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

/** 연 PDF 하나 — 파일 기술자 + 렌더러 + 페이지 크기 목록. `PdfRenderer` 는 한 번에 한 페이지만 열 수 있어 [lock] 으로 줄 세운다. */
private class PdfDoc private constructor(
    private val dir: File,
    private val fd: ParcelFileDescriptor,
    private val renderer: PdfRenderer,
    val sizes: List<Pair<Int, Int>>,
) {
    private val lock = Mutex()
    @Volatile private var closed = false

    /** 페이지 [index] 를 [w]×[h] 비트맵으로(흰 바탕). 닫혔거나 실패하면 null. */
    suspend fun render(index: Int, w: Int, h: Int): Bitmap? = lock.withLock {
        if (closed) return@withLock null
        try {
            renderer.openPage(index).use { page ->
                val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                bitmap.eraseColor(android.graphics.Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                bitmap
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "pdf page render failed: ${e.javaClass.simpleName}")
            null
        } catch (e: OutOfMemoryError) {
            Log.w(TAG, "pdf page render out of memory")
            null
        }
    }

    /** 렌더러·기술자를 닫고 임시 파일을 지운다. 그리는 중이면 그 페이지가 끝난 뒤에(lock) — 화면 스레드를 막지 않게 IO 에서 부른다. */
    suspend fun close() {
        closed = true
        lock.withLock {
            runCatching { renderer.close() }
            runCatching { fd.close() }
        }
        dir.deleteRecursively()
    }

    companion object {
        private const val TAG = "hande.pdf"
        private const val OPEN_DIR = "hande-open"

        /**
         * 바이트를 앱 cache `hande-open/<nanoTime>/attachment.pdf` 에 쓰고 연다. 보호된(비밀번호) PDF 는 `SecurityException`,
         * 손상 파일은 `IOException` — 둘 다 null(호출자가 「열 수 없음」으로). IO 스레드에서 부른다.
         */
        fun open(context: Context, bytes: ByteArray): PdfDoc? {
            val dir = File(context.cacheDir, "$OPEN_DIR/${System.nanoTime()}").apply { mkdirs() }
            var fd: ParcelFileDescriptor? = null
            var renderer: PdfRenderer? = null
            return try {
                val file = File(dir, "attachment.pdf").apply { writeBytes(bytes) }
                val f = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).also { fd = it }
                val r = PdfRenderer(f).also { renderer = it }
                val sizes = (0 until r.pageCount).map { i -> r.openPage(i).use { page -> page.width to page.height } }
                if (sizes.isEmpty()) throw IOException("no pages")
                PdfDoc(dir, f, r, sizes)
            } catch (e: IOException) {
                Log.w(TAG, "pdf open failed: ${e.javaClass.simpleName}")
                runCatching { renderer?.close() }; runCatching { fd?.close() }; dir.deleteRecursively(); null
            } catch (e: SecurityException) {
                Log.w(TAG, "pdf is protected")
                runCatching { renderer?.close() }; runCatching { fd?.close() }; dir.deleteRecursively(); null
            } catch (e: RuntimeException) {
                Log.w(TAG, "pdf open failed: ${e.javaClass.simpleName}")
                runCatching { renderer?.close() }; runCatching { fd?.close() }; dir.deleteRecursively(); null
            }
        }

        /** 허브 시작 때(`AttachmentIo.clearShared`): 지난 실행이 남긴 PDF 임시 파일을 지운다. */
        fun clearOpenDir(context: Context) {
            File(context.cacheDir, OPEN_DIR).deleteRecursively()
        }
    }
}

/** 뷰어 상태: 여는 중 · 열림 · 열 수 없음(보호·손상). */
private sealed interface PdfState {
    data object Loading : PdfState
    class Ready(val doc: PdfDoc) : PdfState
    data object Failed : PdfState
}

/**
 * 첨부 PDF 뷰어(#698 C3): 어두운 바탕 전체 화면 Dialog — 페이지를 화면 폭에 맞춰 세로로 이어 보이고(보이는 페이지만 그린다),
 * 두 손가락으로 1~4배 확대(확대 중에는 끌어서 옮기기). 아래 「공유」·「다른 앱으로 열기」·「닫기」는 이미지 뷰어와 같다.
 * 열 수 없으면(비밀번호 PDF·손상) 「열 수 없음」 문구와 같은 버튼만 남는다 — 저장/공유로 떨어진다(C3 설계).
 */
@Composable
internal fun PdfViewer(opened: AttachmentFiles.Opened, onShare: () -> Unit, onOpenWith: () -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    val state by produceState<PdfState>(initialValue = PdfState.Loading, opened) {
        // 여는 중에 뷰어를 닫아도 연 문서를 버리지 않게(파일 기술자·임시 파일) 여는 동안은 취소하지 않고, 이미 닫혔으면 바로 정리한다.
        val doc = withContext(Dispatchers.IO + NonCancellable) { PdfDoc.open(context.applicationContext, opened.bytes) }
        if (!isActive) {
            doc?.let { d -> CoroutineScope(Dispatchers.IO).launch { d.close() } }
            return@produceState
        }
        value = if (doc != null) PdfState.Ready(doc) else PdfState.Failed
    }
    val ready = state as? PdfState.Ready
    DisposableEffect(ready) {
        // 닫을 때 정리는 화면 스레드 밖에서(그리는 중인 페이지를 기다릴 수 있다). Dialog 가 사라진 뒤에도 끝까지 돈다.
        onDispose { ready?.doc?.let { doc -> CoroutineScope(Dispatchers.IO).launch { doc.close() } } }
    }
    var zoom by remember(opened) { mutableFloatStateOf(1f) }
    var pan by remember(opened) { mutableStateOf(Offset.Zero) }
    val transform = rememberTransformableState { zoomChange, panChange, _ ->
        zoom = PdfPages.clampZoom(zoom * zoomChange)
        pan = if (zoom <= PdfPages.MIN_ZOOM) Offset.Zero else pan + panChange
    }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(Color(0xFF202124))) {
            BoxWithConstraints(
                Modifier.weight(1f).fillMaxWidth()
                    // 한 손가락 끌기는 확대했을 때만 옮기기 — 1배에서는 목록 스크롤로 간다.
                    .transformable(transform, canPan = { zoom > PdfPages.MIN_ZOOM }),
                contentAlignment = Alignment.Center,
            ) {
                when (val s = state) {
                    PdfState.Loading -> Text(Strings.attachmentOpening, color = Color.White)
                    PdfState.Failed -> Text(Strings.attachmentPdfUnreadable, color = Color.White, modifier = Modifier.padding(24.dp))
                    is PdfState.Ready -> {
                        val viewWidthPx = with(LocalDensity.current) { maxWidth.roundToPx() }
                        LazyColumn(
                            Modifier.fillMaxSize().graphicsLayer {
                                scaleX = zoom; scaleY = zoom
                                translationX = pan.x; translationY = pan.y
                            },
                            contentPadding = PaddingValues(vertical = 8.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            itemsIndexed(s.doc.sizes) { index, (pw, ph) ->
                                PdfPageItem(s.doc, index, s.doc.sizes.size, pw, ph, viewWidthPx)
                            }
                        }
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                TextButton(onClick = onShare) { Text(Strings.attachmentShare, color = Color.White) }
                TextButton(onClick = onOpenWith) { Text(Strings.attachmentOpenWith, color = Color.White) }
                TextButton(onClick = onClose) { Text(Strings.close, color = Color.White) }
            }
        }
    }
}

/** 페이지 하나 — 자리는 페이지 비율로 먼저 잡고, 화면에 들어오면 그린다. 화면에서 빠지면 비트맵을 놓는다. */
@Composable
private fun PdfPageItem(doc: PdfDoc, index: Int, count: Int, pageWidth: Int, pageHeight: Int, viewWidthPx: Int) {
    val bitmap by produceState<Bitmap?>(initialValue = null, doc, index, viewWidthPx) {
        val size = PdfPages.renderSize(pageWidth, pageHeight, viewWidthPx)
        value = size?.let { (w, h) -> withContext(Dispatchers.IO) { doc.render(index, w, h) } }
    }
    DisposableEffect(bitmap) {
        val held = bitmap
        onDispose { held?.recycle() }
    }
    val label = PdfPages.pageLabel(index, count)
    Box(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp)
            .aspectRatio(1f / PdfPages.aspect(pageWidth, pageHeight))
            .background(Color.White)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        val b = bitmap
        if (b != null && !b.isRecycled) {
            Image(b.asImageBitmap(), contentDescription = null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        } else {
            Text(label, color = Color.Gray)
        }
    }
}

/** `AttachmentIo.clearShared` 에서 부른다 — PDF 임시 파일 디렉터리 정리. */
internal fun clearPdfOpenDir(context: Context) = PdfDoc.clearOpenDir(context)
