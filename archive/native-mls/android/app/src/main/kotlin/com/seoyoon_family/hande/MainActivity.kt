// 앱 Activity 하나(`singleTask`): 가족 로그인 콜백 `hande://auth#…` 은 새 인스턴스가 아니라 `onNewIntent` 로 들어온다(브라우저에서 앱으로 복귀, #338 B2).
// 프로세스가 죽은 뒤 콜백이 오면 `onCreate` 의 intent 로 온다 — 두 경로 모두 `DeviceHub.completeLogin` 으로.
package com.seoyoon_family.hande

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.lifecycle.lifecycleScope
import com.seoyoon_family.hande.core.AppLogin
import com.seoyoon_family.hande.ui.HandeRoot

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as HandeApp
        app.hub.start(lifecycleScope)
        setContent {
            MaterialTheme { HandeRoot(app.hub) }
        }
        handleCallback(intent)
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
