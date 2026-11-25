// 말풍선 꾹 누르기 메뉴 — iOS `MessageCopyMenu`(MessageCopy.swift) 의 Android 판. 항목·순서·말이 같다: 「답장」 · 「복사」 · 「선택해서 복사」 · 「공유」.
// 「답장」은 보낼 수 있는 방에서만, 「공유」는 시스템 공유 시트로 글만(첨부·설명자는 대상이 아니다 — #499). 대상 글 규칙은 `core/MessageCopy`.
package com.seoyoon_family.hande.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.size
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import com.seoyoon_family.hande.ui.theme.HandeIcons
import com.seoyoon_family.hande.ui.theme.LocalHandeColors

/**
 * 말풍선을 꾹 누르면(시스템 길게 누르기 시간 · 손가락이 거의 안 움직임) [onLongPress]. 그 전의 누르기·링크·가로 스크롤·밀어서 답장·타임라인 스크롤은
 * 종전 그대로 받는다(움직이거나 안쪽이 먼저 먹으면 포기). 메뉴를 연 뒤 같은 손가락의 나머지(떼기 포함)는 안쪽보다 먼저(Initial) 먹는다 —
 * 링크가 함께 열리거나 답장 끌기·스크롤이 뒤따르지 않게. TalkBack 은 「길게 누르기」 동작으로 같은 메뉴를 연다.
 */
@Composable
internal fun Modifier.messageLongPress(label: String, onLongPress: () -> Unit): Modifier {
    val latest by rememberUpdatedState(onLongPress)
    return this
        .pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                val longPressed = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                    var gone = false
                    while (!gone) {
                        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id }
                        gone = change == null || !change.pressed || change.isConsumed ||
                            (change.position - down.position).getDistance() > viewConfiguration.touchSlop
                    }
                    false
                } ?: true
                if (!longPressed) return@awaitEachGesture
                latest()
                while (true) {
                    val event = awaitPointerEvent(PointerEventPass.Initial)
                    event.changes.forEach { it.consume() }
                    if (event.changes.none { it.pressed }) break
                }
            }
        }
        .semantics { onLongClick(label) { latest(); true } }
}

/** 말풍선에 붙는 메뉴(말풍선 아래, 자리가 없으면 위). [onReply] 가 null 이면(보낼 수 없는 방) 「답장」 항목이 없다. */
@Composable
internal fun MessageMenu(expanded: Boolean, onDismiss: () -> Unit, text: String, onReply: (() -> Unit)?, onSelectCopy: (String) -> Unit) {
    val colors = LocalHandeColors.current
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val copy: () -> Unit = {
        clipboard.setText(AnnotatedString(text))
        // 버전을 가리지 않고 직접 알린다(#894) — Android 13+ 의 시스템 복사 알림은 기기에 따라 없다(고7 실측). 앱의 다른 복사 경로와 같은 동작.
        Toast.makeText(context, Strings.copiedToast, Toast.LENGTH_SHORT).show()
    }
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        if (onReply != null) MessageMenuItem(Strings.messageReply, HandeIcons.reply(colors.ink), onDismiss, onReply)
        MessageMenuItem(Strings.messageCopy, HandeIcons.copy(colors.ink), onDismiss, copy)
        MessageMenuItem(Strings.messageSelectCopy, HandeIcons.selectText(colors.ink), onDismiss) { onSelectCopy(text) }
        MessageMenuItem(Strings.messageShare, HandeIcons.share(colors.ink), onDismiss) { shareMessage(context, text, onFailed = copy) }
    }
}

@Composable
private fun MessageMenuItem(label: String, icon: ImageVector, onDismiss: () -> Unit, action: () -> Unit) {
    DropdownMenuItem(
        text = { Text(label) },
        leadingIcon = { Icon(icon, contentDescription = null, Modifier.size(20.dp), tint = Color.Unspecified) },
        onClick = {
            onDismiss()
            action()
        },
    )
}

/** 「공유」: 시스템 공유 시트(ACTION_SEND, text/plain)로 글만. 받을 앱이 없으면 [onFailed](복사로 대신한다). */
private fun shareMessage(context: Context, text: String, onFailed: () -> Unit) {
    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
    try {
        context.startActivity(Intent.createChooser(send, null))
    } catch (_: ActivityNotFoundException) {
        onFailed()
    }
}
