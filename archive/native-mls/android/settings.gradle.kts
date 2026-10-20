// 「한데」 Android 앱 (#338 B) — Gradle 설정. 모듈은 `:app` 하나. 바인딩·`.so` 는 `../ios-ffi/build-android.sh` 산출물(`-PhandeFfiOut=` 로 바꿀 수 있다).
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "hande-android"
include(":app")
