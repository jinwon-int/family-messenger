// 앱 설정(SharedPreferences). 비밀은 세션 값(CF Access 토큰) 하나 — Keystore 로 봉인해 base64 로 둔다. 나머지는 공개 값.
// 기기 ID = `<actor>-android-<6 hex>`(iOS 의 `<actor>-iphone-<6 hex>` 와 같은 모양). 접미는 한 번 만들고 고정 — 바꾸면 다른 기기다.
package com.seoyoon_family.hande.core

import android.content.Context
import android.util.Base64
import java.security.SecureRandom

class Settings(context: Context, private val sealer: KeystoreSealer) {
    private val prefs = context.getSharedPreferences("hande", Context.MODE_PRIVATE)

    var relayUrl: String?
        get() = prefs.getString("relay_url", null)?.takeIf { it.isNotBlank() }
        set(value) { prefs.edit().putString("relay_url", value?.trim()?.trimEnd('/')).apply() }

    /** 가족 운영자가 정해 준 영문 이름(소문자 시작, 영문 소문자·숫자 2~16자). 한 번 정하면 바꿀 수 없다(기기 ID 의 일부). */
    var actor: String?
        get() = prefs.getString("actor", null)?.takeIf { it.isNotBlank() }
        set(value) { prefs.edit().putString("actor", value).apply() }

    val deviceSuffix: String
        get() = prefs.getString("device_suffix", null) ?: ByteArray(3).also { SecureRandom().nextBytes(it) }
            .joinToString("") { "%02x".format(it) }
            .also { prefs.edit().putString("device_suffix", it).apply() }

    val deviceId: String? get() = actor?.let { "$it-android-$deviceSuffix" }

    /** CF Access 세션 값(운영자용 직접 입력). 저장은 봉인본. */
    var accessToken: String?
        get() = prefs.getString("access_token_sealed", null)?.let {
            runCatching { String(sealer.open(Base64.decode(it, Base64.NO_WRAP)), Charsets.UTF_8) }.getOrNull()
        }?.takeIf { it.isNotBlank() }
        set(value) {
            if (value.isNullOrBlank()) prefs.edit().remove("access_token_sealed").apply()
            else prefs.edit().putString("access_token_sealed", Base64.encodeToString(sealer.seal(value.trim().toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)).apply()
        }

    /** 진행 중인 가족 로그인의 `state`(비밀 아님 — 공개 난수). 브라우저가 열려 있는 동안 프로세스가 죽어도 콜백을 검증할 수 있게 둔다. */
    var pendingLoginState: String?
        get() = prefs.getString("login_state", null)?.takeIf { it.isNotBlank() }
        set(value) { if (value == null) prefs.edit().remove("login_state").apply() else prefs.edit().putString("login_state", value).apply() }

    val isConfigured: Boolean get() = relayUrl != null && actor != null

    companion object {
        private val ACTOR = Regex("^[a-z][a-z0-9]{1,15}$")
        fun validActor(s: String) = ACTOR.matches(s)
    }
}
