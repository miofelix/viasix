import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Release keystore lives at monorepo signing/android/ (see signing/README.md).
// Private material is gitignored; local keystore.properties is required for signed APK.
val keystorePropertiesFile =
    rootProject.file("../../signing/android/keystore.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "dev.viasix.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.viasix.app"
        minSdk = 26
        targetSdk = 35
        // Platform-independent Android versioning.
        versionCode = 2
        versionName = "1.0.1"
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                val storePath = keystoreProperties.getProperty("storeFile")
                    ?: error("signing/android/keystore.properties missing storeFile")
                storeFile = file(storePath)
                storePassword = keystoreProperties.getProperty("storePassword")
                    ?: error("signing/android/keystore.properties missing storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                    ?: error("signing/android/keystore.properties missing keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                    ?: error("signing/android/keystore.properties missing keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
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
        buildConfig = true
    }

    packaging {
        jniLibs {
            // Android 10+ forbids executing binaries copied into filesDir. CFST is
            // packaged as a native library and must be extracted to nativeLibraryDir.
            useLegacyPackaging = true
            // mihomo + CFST are plain Go ELF binaries named lib*.so so PackageManager
            // extracts them to nativeLibraryDir (executable). Preserve symbols/size.
            keepDebugSymbols += "**/libcfst.so"
            keepDebugSymbols += "**/libmihomo.so"
        }
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    implementation(project(":core"))
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7")
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
}
