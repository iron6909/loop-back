import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties().apply {
    val keystorePropertiesFile = rootProject.file("key.properties")
    if (keystorePropertiesFile.exists()) {
        load(keystorePropertiesFile.inputStream())
    }
}

android {
    namespace = "app.loopback"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.loopback"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // ffmpeg_kit_flutter_new_audio requires Android API 24+.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只打包 arm64
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    packaging {
        jniLibs {
            // 强制排除非 arm64 的 so，防止 Flutter 插件绕过 abiFilters
            excludes += listOf("lib/x86_64/**", "lib/armeabi-v7a/**", "lib/x86/**")
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    buildTypes {
        release {
            // release 构建启用 R8（Flutter/AGP 默认行为，见 build 产物
            // minifyProdReleaseWithR8 / mapping.txt）。此处显式接入 app 级
            // proguard 规则——ffmpeg_kit 等插件的 keep 规则未通过
            // consumerProguardFiles 传播到宿主，必须在 app/proguard-rules.pro
            // 中保留，否则 R8 会裁掉仅由 JNI_OnLoad 反射注册的 native 方法，
            // 导致插件注册整体失败、App 卡在启动 splash。
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // 与 iOS 的 dev / prod scheme 保持一致：
    // dev  -> app.loopback.dev  / "LoopBack Dev"
    // prod -> app.loopback      / "LoopBack"
    // 这里按 flavor 固定签名：dev 使用 debug 证书，prod 使用 release 证书。
    // 这样同一个 package 的 debug / release 会保持同一把签名，便于 Google 登录配置。
    flavorDimensions += "env"
    productFlavors {
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "LoopBack Dev")
        }
        create("prod") {
            dimension = "env"
            resValue("string", "app_name", "LoopBack")
        }
    }
}

androidComponents {
    onVariants(selector().all()) { variant ->
        if (variant.name.startsWith("prod")) {
            // prod 必须用发布密钥签名。缺 key.properties 时 AGP 会静默回落 debug 证书，
            // 产出与既有安装签名不一致的同名包：用户升级时报 signature mismatch，
            // 且旧包只能卸载重装（2026-11-12 的 1.0.46 就踩了这个坑）。
            // 宁可在配置阶段失败，也不要再发出第二把 key 签过的包。
            val storeFile = keystoreProperties.getProperty("storeFile")
            if (storeFile.isNullOrBlank()) {
                throw GradleException(
                    "prod 变体缺少发布密钥：android/key.properties 不存在或未配置 " +
                        "storeFile。请先恢复发布密钥（CI secrets 或离线备份）再构建。",
                )
            }
            variant.signingConfig.setConfig(
                android.signingConfigs.getByName("release"),
            )
        } else if (variant.name.startsWith("dev")) {
            variant.signingConfig.setConfig(
                android.signingConfigs.getByName("debug"),
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Android 12+ 使用系统启动页；compat 主题同时保持旧版 layer-list 的一致行为。
    implementation("androidx.core:core-splashscreen:1.0.1")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    testImplementation("junit:junit:4.13.2")
    // flutter-plugin-loader 将 integration_test (dev_dependency) 只注入 debugImplementation，
    // 但 GeneratedPluginRegistrant.java 在所有构建变体中均引用该类，导致 release 编译失败。
    // 此处补充 releaseImplementation 使编译通过；try-catch 保证运行时初始化失败不影响 app。
    releaseImplementation(project(":integration_test"))
}
