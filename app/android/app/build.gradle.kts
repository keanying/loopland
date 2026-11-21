import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 配置（均已 gitignore）──────────────────────────────────────────────────
// 唯一来源是 config/app.yaml（+ 本机 config/app.local.yaml），运行
//   dart run tool/gen_config.dart --profile dev
// 生成 android/loopland.properties（勿手改）：AMAP_ANDROID_KEY（manifestPlaceholders）、
// LOOPLAND_PROFILE、KEY_PROPERTIES（release 签名文件路径，app.yaml 的 android.key_properties）。
// release 签名的密码单独放在 android/key.properties（模板 key.properties.example），不进 app.yaml。
fun loadProps(name: String): Properties {
    val p = Properties()
    val f = rootProject.file(name)
    if (f.exists()) f.inputStream().use { p.load(it) }
    return p
}

val looplandProps = loadProps("loopland.properties")
val keyPropertiesPath = looplandProps.getProperty("KEY_PROPERTIES")?.takeIf { it.isNotBlank() } ?: "key.properties"
val keyProps = loadProps(keyPropertiesPath)

// `--dart-define` / `--dart-define-from-file` values, which Flutter hands to
// Gradle base64-encoded in the `dart-defines` property (later entries win, so
// an explicit --dart-define beats the file — same as on the Dart side).
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.mapNotNull {
            val kv = String(Base64.getDecoder().decode(it), Charsets.UTF_8).split("=", limit = 2)
            if (kv.size == 2) kv[0] to kv[1] else null
        }
        ?.toMap() ?: emptyMap()

// dart-define (same source: config/<profile>.json) first, then the generated
// loopland.properties (builds without --dart-define-from-file, e.g. Android Studio).
fun sdkValue(key: String): String =
    dartDefines[key]?.takeIf { it.isNotBlank() } ?: looplandProps.getProperty(key)?.takeIf { it.isNotBlank() } ?: ""

// loopland.properties holds the last generated profile; warn when it differs
// from the --dart-define-from-file one.
run {
    val built = dartDefines["LOOPLAND_CONFIG_PROFILE"].orEmpty()
    val native = looplandProps.getProperty("LOOPLAND_PROFILE").orEmpty()
    if (built.isNotEmpty() && native.isNotEmpty() && built != native) {
        logger.warn("圈圈: android/loopland.properties 是 profile「$native」生成的，本次构建用「$built」。请运行 dart run tool/gen_config.dart --profile $built")
    }
}

android {
    namespace = "com.loopland.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.loopland.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 高德 Key → <meta-data android:name="com.amap.api.v2.apikey">
        manifestPlaceholders["AMAP_ANDROID_KEY"] = sdkValue("AMAP_ANDROID_KEY")
    }

    signingConfigs {
        create("release") {
            if (keyProps.getProperty("storeFile") != null) {
                storeFile = rootProject.file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keyProps.getProperty("storeFile") != null) {
                signingConfigs.getByName("release")
            } else if (project.hasProperty("allowDebugSigning")) {
                // Local only: flutter build apk --release -PallowDebugSigning
                // Such an APK must never be uploaded — WeChat / Alipay / AMap /
                // 号码认证 are bound to the release signature.
                logger.warn("圈圈: 使用 debug 签名构建 release 包（仅本地测试，不可上架）")
                signingConfigs.getByName("debug")
            } else {
                null
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

// Refuse to produce an unsigned / wrongly signed release package.
gradle.taskGraph.whenReady {
    val releaseTask = allTasks.any { it.project == project && it.name.contains("Release") && (it.name.startsWith("assemble") || it.name.startsWith("bundle")) }
    if (releaseTask && keyProps.getProperty("storeFile") == null && !project.hasProperty("allowDebugSigning")) {
        throw GradleException("缺少 android/$keyPropertiesPath（release 签名，路径见 config/app.yaml 的 android.key_properties）。参考 android/key.properties.example；仅本地测试可加 -PallowDebugSigning")
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
