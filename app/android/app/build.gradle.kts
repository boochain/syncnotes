plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun envOr(name: String, fallback: String): String {
    val v = System.getenv(name)
    return if (v.isNullOrBlank()) fallback else v
}

android {
    namespace = "com.frec86.syncnotes"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.frec86.syncnotes"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // SDK 依赖信息会写进签名块（id 0x504b4453）。部分手机安装器把带这个块、
    // 又没有 v1 签名的包直接判成「安装包无效」。
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    // 固定正式签名，避免每次 CI 都换一把调试证书（覆盖安装会被手机判成「安装包无效」）。
    // 环境变量优先：配了 GitHub Actions secret 就用 secret，否则用仓库里的 syncnotes-release.p12。
    val keystorePath = System.getenv("SYNCNOTES_KEYSTORE")
    val keystoreFile = if (keystorePath.isNullOrBlank()) file("syncnotes-release.p12") else file(keystorePath)
    val hasReleaseKey = keystoreFile.exists()

    signingConfigs {
        getByName("debug") {
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
        if (hasReleaseKey) {
            create("release") {
                storeFile = keystoreFile
                storeType = "pkcs12"
                storePassword = envOr("SYNCNOTES_STORE_PASSWORD", "snotes-rel-7f3c1a9e")
                keyAlias = envOr("SYNCNOTES_KEY_ALIAS", "syncnotes")
                keyPassword = envOr("SYNCNOTES_KEY_PASSWORD", "snotes-rel-7f3c1a9e")
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
                enableV4Signing = false
            }
        }
    }

    buildTypes {
        release {
            // CI 注入固定的正式密钥。没有密钥时才退回调试签名（本地 flutter run）。
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
