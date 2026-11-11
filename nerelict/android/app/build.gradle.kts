import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.nerelict.nerelict"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.nerelict.nerelict"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        // 版本号统一以 pubspec 的三段版本为唯一来源：
        // version = 0.4.0+20 → versionName 0.4.0 / versionCode 20。
        // 不再覆盖第四段，避免设置页、README 与设备显示三处不一致。
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 发布构建只保留 arm64-v8a：Flutter 引擎只有这一套，其它 ABI 只剩插件的小 so，
    // 设备能装但启动会崩。这里在打包阶段剔除，让不支持的设备直接报不兼容。
    // 需要模拟器时删掉这两条，或按 README 用 --target-platform 指定。
    packaging {
        jniLibs {
            excludes += listOf("lib/armeabi-v7a/**", "lib/x86_64/**")
        }
    }

    signingConfigs {
        create("release") {
            // 签名材料放在 android/key.properties（含本机路径与密码，已忽略、不入库）。
            // 文件缺失时留空，由下面的 buildTypes 回退到 debug 签名，
            // 保证他人 clone 后无需任何配置也能构建。
            val propsFile = rootProject.file("key.properties")
            if (propsFile.exists()) {
                val props = Properties().apply {
                    propsFile.inputStream().use { load(it) }
                }
                props.getProperty("storeFile")?.let { storeFile = file(it) }
                storePassword = props.getProperty("storePassword")
                keyAlias = props.getProperty("keyAlias")
                keyPassword = props.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 配了正式签名就用它发布；没配则回退 debug 签名，便于本地验证与他人构建。
            signingConfig = if (signingConfigs.getByName("release").storeFile != null) {
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
    // FileProvider（把安装包安全地交给系统安装器）
    implementation("androidx.core:core-ktx:1.13.1")
}
