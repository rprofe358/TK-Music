plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "org.sonora.mobile"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.sonora.mobile"
        minSdk = 26
        targetSdk = 35
        // 1000 + compilación: siempre mayor que las del repo anterior (llegaron a 28), para que
        // Android acepte la actualización encima sin desinstalar.
        versionCode = 1000 + (System.getenv("GITHUB_RUN_NUMBER") ?: "0").toInt()
        // En una versión publicada (etiqueta v1.2.3) el nombre es el de la etiqueta.
        versionName = System.getenv("TK_VERSION") ?: "0.1.${System.getenv("GITHUB_RUN_NUMBER") ?: "0"}"
    }

    // Una clave fija, para que cada APK nuevo se instale encima del anterior.
    signingConfigs {
        create("sonora") {
            storeFile = file("../keystore/sonora.jks")
            storePassword = "sonora-android"
            keyAlias = "sonora"
            keyPassword = "sonora-android"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("sonora")
            // Celulares, TV y proyectores son ARM; TK_ABIS=x86_64 arma la versión para el emulador del PC.
            ndk { abiFilters += (System.getenv("TK_ABIS")?.split(",") ?: listOf("arm64-v8a", "armeabi-v7a")) }
        }
        debug {
            signingConfig = signingConfigs.getByName("sonora")
            // En depuración local (Android Studio) incluye x86_64 para que el emulador arranque sin variables extra.
            ndk { abiFilters += (System.getenv("TK_ABIS")?.split(",") ?: listOf("arm64-v8a", "armeabi-v7a", "x86_64")) }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
    packaging { jniLibs { useLegacyPackaging = true } }
}

dependencies {
    val compose = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(compose)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.navigation:navigation-compose:2.8.5")
    implementation("androidx.media:media:1.7.0")
    implementation("androidx.webkit:webkit:1.12.1")
    implementation("androidx.browser:browser:1.8.0")
    implementation("androidx.palette:palette-ktx:1.0.0")
    implementation("com.airbnb.android:lottie-compose:6.6.0")
    implementation("io.coil-kt.coil3:coil-compose:3.0.4")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.0.4")
    // UniFFI llama al motor en Rust a través de JNA.
    implementation("net.java.dev.jna:jna:5.15.0@aar")
    // Debe coincidir con rustls-platform-verifier-android en Cargo.lock (0.2.0).
    implementation("org.rustls:rustls-platform-verifier:0.2.0")
}
