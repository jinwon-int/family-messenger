// 「한데」 Android 앱 모듈 (#338 B1 — 앱 골격). 패키지 `com.seoyoon_family.hande`(#338 G0 코멘트), minSdk 26(오너 확정 2026-10-13).
// 소스셋: 이 모듈 + 공용 호스트 어댑터(`../host/src/main/kotlin`: JdkHttpTransport · FileRoomStore · FileLobbyStore) +
// uniffi Kotlin 바인딩(`<ffiOut>/kotlin`). 네이티브는 `<ffiOut>/jniLibs/<abi>/libfamily_mls_ios_ffi.so`.
// `ffiOut` 기본 = `../../ios-ffi/out/android`(build-android.sh 출력), CI 는 `-PhandeFfiOut=` 로 아티팩트 경로를 준다.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

val ffiOut: File = (findProperty("handeFfiOut") as String?)?.let { file(it) } ?: rootProject.file("../ios-ffi/out/android")

android {
    namespace = "com.seoyoon_family.hande"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.seoyoon_family.hande"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }

    // 디버그 서명키 고정(B1.4): AGP 기본은 러너마다 새 `~/.android/debug.keystore` 를 만들어 CI APK 서명이 매번 달라진다 →
    // 실기기 `adb install -r` 이 INSTALL_FAILED_UPDATE_INCOMPATIBLE 로 거부(공융 2026-10-20, 재설치 3회 무효). 표준 디버그 자격
    // (`androiddebugkey` / `android`, 공개값)의 PKCS12 를 커밋해 디버그 빌드만 서명한다. **릴리스 서명에는 절대 쓰지 않는다**(E 단계 Play App Signing).
    signingConfigs {
        getByName("debug") {
            storeFile = file("debug.keystore")
            storeType = "PKCS12"
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures { compose = true }

    sourceSets {
        getByName("main") {
            kotlin.srcDirs(rootProject.file("host/src/main/kotlin"), File(ffiOut, "kotlin"))
            jniLibs.srcDirs(File(ffiOut, "jniLibs"))
        }
    }

    packaging {
        jniLibs { useLegacyPackaging = false }
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.kotlinx.coroutines.android)
    // 릴레이 전송(#338 §2 RelayClient). HttpURLConnection 은 CF Access/HTTP2 엣지에서 멈춘다(실기기 공융 build fa4f286)
    // — OkHttp 는 HTTP/2 협상·강제 타임아웃·리다이렉트 무추적을 제대로 한다.
    implementation(libs.okhttp)
    // uniffi Kotlin 바인딩의 런타임 요구(#338 §5·android/README 의존성 표). Android 는 aar(libjnidispatch.so 포함).
    implementation("net.java.dev.jna:jna:${libs.versions.jna.get()}@aar")
}

tasks.register("ffiOutCheck") {
    description = "build-android.sh 산출물이 있는지 확인한다(없으면 어디서 만드는지 안내)."
    doLast {
        check(File(ffiOut, "kotlin").isDirectory && File(ffiOut, "jniLibs").isDirectory) {
            "FFI output not found under $ffiOut — run archive/native-mls/ios-ffi/build-android.sh (or pass -PhandeFfiOut=<dir>)"
        }
    }
}
tasks.matching { it.name.startsWith("preBuild") }.configureEach { dependsOn("ffiOutCheck") }
