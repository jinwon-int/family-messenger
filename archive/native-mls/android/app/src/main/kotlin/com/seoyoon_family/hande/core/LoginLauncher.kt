// 로그인 창 열기(#338 B2): Chrome Custom Tabs(`androidx.browser`) — 브라우저 본체의 Google·Access 세션을 함께 쓰므로 세션이 만료돼 다시
// 로그인할 때 대개 한 번의 탭으로 끝난다(iOS `prefersEphemeralWebBrowserSession = false` 와 같은 선택). Custom Tabs 제공자가 없으면
// 일반 브라우저 intent 로 폴백한다(리다이렉트 `hande://auth` 는 어느 쪽이든 이 앱의 intent-filter 로 돌아온다). 브라우저가 아예 없으면 `CannotStart`.
package com.seoyoon_family.hande.core

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent

object LoginLauncher {
    fun open(context: Context, url: String) {
        val uri = Uri.parse(url)
        try {
            CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, uri)
        } catch (_: ActivityNotFoundException) {
            try {
                context.startActivity(Intent(Intent.ACTION_VIEW, uri))
            } catch (_: ActivityNotFoundException) {
                throw AppLogin.Failure.CannotStart
            }
        }
    }
}
