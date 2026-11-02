plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// 서명 정보는 코드에 넣지 않고, 빌드할 때 환경변수(GitHub Secrets)로 받음
val keystorePath: String? = System.getenv("ANDROID_KEYSTORE_PATH")
val hasReleaseKey = keystorePath != null && file(keystorePath).exists()

android {
    namespace = "com.blelcd.remote"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.blelcd.remote"
        minSdk = 26          // Android 8.0 이상
        targetSdk = 36       // Google Play 요구사항 (2026-08-31부터 API 36)
        // 빌드할 때마다 자동으로 올라감 (Play에 올릴 때마다 versionCode가 커야 함)
        versionCode = (System.getenv("VERSION_CODE") ?: "1").toInt()
        versionName = "1.0." + (System.getenv("VERSION_CODE") ?: "0")
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystorePath!!)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (hasReleaseKey) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.webkit:webkit:1.14.0")
}
