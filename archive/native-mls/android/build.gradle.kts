// 루트: 플러그인 버전만 선언(적용은 :app). 버전 핀은 gradle/libs.versions.toml(#177 원칙 5).
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
