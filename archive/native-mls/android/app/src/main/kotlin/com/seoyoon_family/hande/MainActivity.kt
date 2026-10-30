// 앱 Activity 하나(`singleTask`): 가족 로그인 콜백 `hande://auth#…` 은 새 인스턴스가 아니라 `onNewIntent` 로 들어온다(브라우저에서 앱으로 복귀, #338 B2).
// 프로세스가 죽은 뒤 콜백이 오면 `onCreate` 의 intent 로 온다 — 두 경로 모두 `DeviceHub.completeLogin` 으로.
// 테마(한데 디자인 1차): `Settings.theme` 의 밤/낮불을 `HandeTheme` 로 제공하고, edge-to-edge 시스템 바 아이콘 색도 모드를 따른다(밤 = 밝은 아이콘, 낮불 = 어두운 아이콘).
package com.seoyoon_family.hande

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.lifecycleScope
import com.seoyoon_family.hande.core.AppLogin
import com.seoyoon_family.hande.core.HandeThemeMode
import com.seoyoon_family.hande.ui.HandeRoot
import com.seoyoon_family.hande.ui.theme.HandeTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as HandeApp
        val initialMode = HandeThemeMode.fromKey(app.settings.theme)
        applyEdgeToEdge(initialMode)
        app.hub.start(lifecycleScope)
        setContent {
            var mode by remember { mutableStateOf(initialMode) }
            // 설정에서 바꾸면 시스템 바 아이콘 색도 따라간다(enableEdgeToEdge 는 다시 불러도 된다).
            LaunchedEffect(mode) { applyEdgeToEdge(mode) }
            HandeTheme(mode) {
                HandeRoot(app.hub, themeMode = mode, onThemeMode = { mode = it; app.settings.theme = it.key })
            }
        }
        handleCallback(intent)
    }

    /** 투명 시스템 바 + 모드별 아이콘 색. 배경은 Compose 의 `CampfireBackground` 가 화면 끝까지 그린다. */
    private fun applyEdgeToEdge(mode: HandeThemeMode) {
        val transparent = android.graphics.Color.TRANSPARENT
        val style = if (mode == HandeThemeMode.DAY) SystemBarStyle.light(transparent, transparent) else SystemBarStyle.dark(transparent)
        enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleCallback(intent)
    }

    private fun handleCallback(intent: Intent?) {
        val data = intent?.data ?: return
        if (intent.action != Intent.ACTION_VIEW || data.scheme?.lowercase() != AppLogin.CALLBACK_SCHEME) return
        (application as HandeApp).hub.completeLogin(lifecycleScope, data.toString())
        intent.data = null // 회전·재생성 때 같은 콜백을 두 번 처리하지 않는다
    }
}
