// 「한데」 Android 앱 모듈 (#338 B1 — 앱 골격). 패키지 `com.seoyoon_family.hande`(#338 G0 코멘트), minSdk 26(오너 확정 2026-10-13).
// 소스셋: 이 모듈 + 공용 호스트 어댑터(`../host/src/main/kotlin`: JdkHttpTransport · FileRoomStore · FileLobbyStore) +
// uniffi Kotlin 바인딩(`<ffiOut>/kotlin`). 네이티브는 `<ffiOut>/jniLibs/<abi>/libfamily_mls_ios_ffi.so`.
// `ffiOut` 기본 = `../../ios-ffi/out/android`(build-android.sh 출력), CI 는 `-PhandeFfiOut=` 로 아티팩트 경로를 준다.
// Play 출시(#584): targetSdk 36(신규 앱 요건) · `-PversionCode=`/`-PversionName=` · 업로드 키 release 서명(환경/속성, 없으면 미서명 번들) ·
// 앱 안 정책 링크(`BuildConfig.PRIVACY_URL`·`DELETE_ACCOUNT_URL`). 자세한 절차는 ../README.md 「Google Play 출시」.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

val ffiOut: File = (findProperty("handeFfiOut") as String?)?.let { file(it) } ?: rootProject.file("../ios-ffi/out/android")

/** Gradle 속성(`-Pname=`) 이 먼저, 없으면 환경 변수. 빈 문자열은 없는 것으로 본다. */
fun setting(name: String): String? =
    (findProperty(name) as String?)?.trim()?.takeIf { it.isNotEmpty() } ?: System.getenv(name)?.trim()?.takeIf { it.isNotEmpty() }

// ---- 버전(#584): Play 는 업로드마다 versionCode 가 커져야 한다. CI 는 `-PversionCode=$GITHUB_RUN_NUMBER`(워크플로 하나가 유일한 출처라 단조 증가),
//      versionName 은 `-PversionName=`(workflow_dispatch 입력) — 없으면 아래 기본값. 로컬 기본 1 / 0.1.0 은 내부 테스트 트랙에도 올리지 않는다.
val appVersionCode: Int = setting("versionCode")?.let { it.toIntOrNull() ?: error("-PversionCode must be a positive integer, got '$it'") } ?: 1
val appVersionName: String = setting("versionName") ?: "0.1.0"
require(appVersionCode >= 1) { "-PversionCode must be >= 1, got $appVersionCode" }

// ---- 업로드 키 서명(#584 Play App Signing): 키스토어는 레포 밖(CI secret → 러너 임시 파일). 네 값이 전부 있을 때만 release 서명 설정을 만들고,
//      전부 없으면 **미서명** 번들(설정·빌드는 성공 — Play Console 이 거부하니 눈에 띈다). 일부만 있으면 조용히 미서명으로 가지 않고 설정 단계에서 멈춘다.
//      디버그 키스토어(app/debug.keystore)는 어떤 경우에도 release 에 쓰지 않는다(아래 debug 서명 설정 참고).
val uploadKeystorePath = setting("HANDE_UPLOAD_KEYSTORE")
val uploadStorePassword = setting("HANDE_UPLOAD_KEYSTORE_PASSWORD")
val uploadKeyAlias = setting("HANDE_UPLOAD_KEY_ALIAS")
val uploadKeyPassword = setting("HANDE_UPLOAD_KEY_PASSWORD")
val uploadSettings = listOf(uploadKeystorePath, uploadStorePassword, uploadKeyAlias, uploadKeyPassword)
val uploadSigningReady: Boolean = when (uploadSettings.count { it != null }) {
    0 -> false
    4 -> {
        val ks = file(uploadKeystorePath!!)
        require(ks.isFile) { "HANDE_UPLOAD_KEYSTORE=$uploadKeystorePath is not a file" }
        require(ks.canonicalPath != file("debug.keystore").canonicalPath) { "HANDE_UPLOAD_KEYSTORE must not be the committed debug keystore" }
        true
    }
    else -> error(
        "release signing is half-configured: HANDE_UPLOAD_KEYSTORE / HANDE_UPLOAD_KEYSTORE_PASSWORD / HANDE_UPLOAD_KEY_ALIAS / HANDE_UPLOAD_KEY_PASSWORD " +
            "must be set together (all four) or not at all (unsigned bundle)",
    )
}

// ---- 앱 안 정책 링크(#584, Play: 개인정보처리방침은 앱 안에서도 열려야 하고 계정 삭제 웹 링크가 있어야 한다). 기본은 GitHub Pages 초안 위치
//      (docs/hande/privacy.md · delete-account.md) — Pages 가 켜지기 전이면 `-PHANDE_PRIVACY_URL=`/환경 변수로 바꾼다. https 만 받는다.
fun policyUrl(name: String, default: String): String {
    val url = setting(name) ?: default
    require(url.startsWith("https://") && '"' !in url && '\\' !in url) { "$name must be an https:// URL, got '$url'" }
    return url
}
val privacyUrl = policyUrl("HANDE_PRIVACY_URL", "https://jinwon-int.github.io/family-messenger/hande/privacy")
val deleteAccountUrl = policyUrl("HANDE_DELETE_URL", "https://jinwon-int.github.io/family-messenger/hande/delete-account")

android {
    namespace = "com.seoyoon_family.hande"
    // API 36(Android 16): Play 신규 앱 요건(#584). AGP 8.10.1 이 지원하는 최대 API(gradle/libs.versions.toml).
    compileSdk = 36

    defaultConfig {
        applicationId = "com.seoyoon_family.hande"
        minSdk = 26
        targetSdk = 36
        versionCode = appVersionCode
        versionName = appVersionName
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
        buildConfigField("String", "PRIVACY_URL", "\"$privacyUrl\"")
        buildConfigField("String", "DELETE_ACCOUNT_URL", "\"$deleteAccountUrl\"")
    }

    // 디버그 서명키 고정(B1.4): AGP 기본은 러너마다 새 `~/.android/debug.keystore` 를 만들어 CI APK 서명이 매번 달라진다 →
    // 실기기 `adb install -r` 이 INSTALL_FAILED_UPDATE_INCOMPATIBLE 로 거부(공융 2026-10-20, 재설치 3회 무효). 표준 디버그 자격
    // (`androiddebugkey` / `android`, 공개값)의 PKCS12 를 커밋해 디버그 빌드만 서명한다. **릴리스 서명에는 절대 쓰지 않는다**(Play App Signing).
    signingConfigs {
        getByName("debug") {
            storeFile = file("debug.keystore")
            storeType = "PKCS12"
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
        if (uploadSigningReady) {
            // 업로드 키(Play App Signing 의 upload key). 키스토어 형식은 JDK 17 기본(PKCS12; JKS 도 호환 모드로 열린다).
            create("release") {
                storeFile = file(uploadKeystorePath!!)
                storePassword = uploadStorePassword
                keyAlias = uploadKeyAlias
                keyPassword = uploadKeyPassword
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            // R8 끔(#584 결정): uniffi 바인딩은 JNA 로 `libfamily_mls_ios_ffi.so` 의 심벌을 **이름으로** 찾고(`Native.load` + Structure/Callback 리플렉션),
            // JNA 자체도 리플렉션 기반이라 난독화·축소 규칙을 실기기에서 검증하기 전에는 켜지 않는다. 앱 크기는 Compose 포함 수 MB 수준이라 Play 한도와 무관.
            // 켤 때: `-keep class com.sun.jna.** { *; }` · `-keep class com.seoyoon_family.hande.mls.** { *; }` + 실기기 왕복 확인 뒤 별도 PR.
            isMinifyEnabled = false
            isShrinkResources = false
            // 업로드 키가 없으면 null = 미서명(디버그 키로 되돌아가지 않는다).
            signingConfig = if (uploadSigningReady) signingConfigs.getByName("release") else null
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    sourceSets {
        getByName("main") {
            kotlin.srcDirs(rootProject.file("host/src/main/kotlin"), File(ffiOut, "kotlin"))
            jniLibs.srcDirs(File(ffiOut, "jniLibs"))
        }
    }

    packaging {
        // 압축하지 않고 넣는다(16 KB 페이지 정렬은 .so 자체의 LOAD 정렬 + 미압축 패키징이 전제 — ios-ffi/build-android.sh 가 정렬을 검증한다).
        jniLibs { useLegacyPackaging = false }
    }

    bundle {
        // 3 ABI 모두 하나의 번들에 — Play 가 기기별로 나눠 준다(언어·밀도도 기본 분할).
        abi { enableSplit = true }
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
    // 가족 로그인(#338 B2): Chrome Custom Tabs — Google 은 WebView 로그인을 막는다. 콜백은 hande://auth intent-filter.
    implementation(libs.androidx.browser)
    // JVM 단위 테스트(AppLogin 순수 로직). kotlin-test-junit 은 Kotlin 핀과 같은 버전, JUnit 4 는 전이 의존.
    testImplementation(libs.kotlin.test.junit)
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

tasks.register("releaseSigningReport") {
    description = "release 서명 상태를 알린다(값은 찍지 않는다): 업로드 키 설정 여부 · versionCode/versionName."
    doLast {
        println("hande release signing: ${if (uploadSigningReady) "upload keystore configured" else "NOT configured → unsigned bundle"}")
        println("hande version: $appVersionName ($appVersionCode)")
    }
}
