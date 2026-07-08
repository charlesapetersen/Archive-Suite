plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.archiveprocessor.capture"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.archiveprocessor.capture"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"

        // AppAuth redirect: the reversed-client-ID custom scheme for the Android OAuth client. AppAuth's
        // library manifest binds its RedirectUriReceiverActivity to this scheme via the placeholder.
        manifestPlaceholders["appAuthRedirectScheme"] =
            "com.googleusercontent.apps.YOUR_ANDROID_OAUTH_CLIENT_ID"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true   // exposes BuildConfig.DEBUG for the debug-only deterministic capture-inject test seam
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.02")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // Lifecycle + viewmodel (Compose)
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")

    // CameraX
    val camerax = "1.3.4"
    implementation("androidx.camera:camera-core:$camerax")
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")

    // QR pairing (bundled model, no Play Services required)
    implementation("com.google.mlkit:barcode-scanning:17.3.0")

    // Networking + coroutines
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // On-device Google OAuth for the Drive cloud relay (Custom Tabs + PKCE, RFC 8252).
    implementation("net.openid:appauth:0.11.1")

    // Plain-JVM unit tests (RelayObjectFormat golden byte-check; no emulator/Robolectric).
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")   // org.json for JVM tests (android.jar's is device-only)
}
