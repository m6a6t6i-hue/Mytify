plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    externalNativeBuild { cmake { path = file("../../native/network/CMakeLists.txt"); version = "3.31.6" } }
    namespace = "pl.mytify.mytify"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "pl.mytify.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        externalNativeBuild { cmake { arguments += listOf("-DANDROID_STL=c++_static", "-DCMAKE_BUILD_TYPE=Release") } }
        ndk { abiFilters += listOf("arm64-v8a") }
        minSdk = 26
        targetSdk = 35
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs { getByName("debug") { storeFile = file("signing/mytify-development.jks") } }
    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

android { testOptions { unitTests.isIncludeAndroidResources = true } }
android {
    packaging {
        resources {
            excludes += setOf("META-INF/versions/9/OSGI-INF/MANIFEST.MF", "META-INF/DEPENDENCIES")
        }
    }
}
dependencies {
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-session:1.11.1")
    // SMB 2/3 client (no SMB1). Bouncy Castle supplies MD4/AES-CMAC missing from Android JCE.
    implementation("com.hierynomus:smbj:0.13.0")
    // WebDAV: PROPFIND and HTTPS ranges; playback through the Media3 OkHttp source.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.media3:media3-datasource-okhttp:1.11.1")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
}

tasks.register("mytifyRuntimeArtifacts") {
    doLast {
        configurations.getByName("releaseRuntimeClasspath").resolvedConfiguration.resolvedArtifacts
            .sortedBy { it.moduleVersion.id.toString() }.forEach {
                val id = it.moduleVersion.id
                println("MYTIFY_ARTIFACT|${id.group}|${id.name}|${id.version}|${it.file.absolutePath}")
            }
    }
}

tasks.withType<Test>().configureEach {
    maxHeapSize = "1g"
    testLogging { events("passed", "skipped", "failed") }
    // Real Samba share in CI for the network source tests.
    listOf(
        "MYTIFY_SMB_HOST", "MYTIFY_SMB_SHARE", "MYTIFY_SMB_USER", "MYTIFY_SMB_PASSWORD",
        "MYTIFY_DAV_URL", "MYTIFY_DAV_UNTRUSTED_URL", "MYTIFY_NORANGE_URL", "MYTIFY_DAV_PASSWORD",
        "MYTIFY_SUBSONIC_URL", "MYTIFY_SUBSONIC_USER", "MYTIFY_SUBSONIC_PASSWORD",
    ).forEach { k ->
        System.getenv(k)?.let { environment(k, it) }
    }
    systemProperty("robolectric.dependency.repo.url", "https://repo.maven.apache.org/maven2")
}
