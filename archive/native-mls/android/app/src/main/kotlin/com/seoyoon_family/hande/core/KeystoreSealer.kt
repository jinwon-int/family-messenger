// 봉인 훅(#338 §2 키 보호 · HOST-CONTRACT §3 `persist`): 그룹 상태·로비 슬롯·세션 값을 Android Keystore 의 비수출 AES-256 키로 AES-GCM 봉인한다.
// Jetpack Security(EncryptedFile) 대신 플랫폼 API 만 쓴다 — 의존 0, 같은 키 보호(docs/DEVICE-KEY-CUSTODY.md "Android Keystore 비수출 키").
// StrongBox(API 28+)가 있으면 거기, 없으면 TEE. 사용자 인증 요구 없음(백그라운드 동기화가 열어야 한다).
// 형식: `0x01 ‖ iv(12) ‖ ciphertext‖tag`. 키를 잃으면(기기 초기화·앱 삭제) 상태는 복구 불가 — 설계대로(기기 = 신원).
package com.seoyoon_family.hande.core

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class KeystoreSealer(private val alias: String = "hande-mls-state") {
    private val random = SecureRandom()

    fun seal(plain: ByteArray): ByteArray {
        val iv = ByteArray(12).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(), GCMParameterSpec(128, iv))
        val out = cipher.doFinal(plain)
        return byteArrayOf(VERSION) + iv + out
    }

    fun open(sealed: ByteArray): ByteArray {
        require(sealed.size > 13 && sealed[0] == VERSION) { "sealed blob: bad header" }
        val iv = sealed.copyOfRange(1, 13)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        return cipher.doFinal(sealed, 13, sealed.size - 13)
    }

    /** 키 보관 위치 설명(화면·로그용, 비밀 아님). */
    fun describe(): String {
        val store = KeyStore.getInstance(PROVIDER).apply { load(null) }
        if (!store.containsAlias(alias)) return "키 없음(첫 저장 때 생성)"
        return if (strongBox) "Android Keystore · StrongBox" else "Android Keystore · TEE"
    }

    private var strongBox = false

    /** 이 기기 지우기(#584): 봉인 키를 Keystore 에서 삭제한다(봉인본은 이미 지웠다 — 키만 남겨도 복호화할 것이 없지만 깨끗이). 다음 `seal` 이 새 키를 만든다. */
    @Synchronized
    fun forget() {
        val store = KeyStore.getInstance(PROVIDER).apply { load(null) }
        if (store.containsAlias(alias)) store.deleteEntry(alias)
        strongBox = false
    }

    @Synchronized
    private fun key(): SecretKey {
        val store = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        fun spec(strong: Boolean): KeyGenParameterSpec {
            val b = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(false) // iv 는 우리가 만든다(위 12 바이트, 매번 새로)
                .setUserAuthenticationRequired(false)
            if (strong && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) b.setIsStrongBoxBacked(true)
            return b.build()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                generator.init(spec(strong = true))
                strongBox = true
                return generator.generateKey()
            } catch (_: StrongBoxUnavailableException) {
                // 이 기기에는 StrongBox 가 없다 — TEE 키로.
            }
        }
        generator.init(spec(strong = false))
        return generator.generateKey()
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val VERSION: Byte = 0x01
    }
}
