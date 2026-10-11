import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Read android/key.properties (gitignored) for the Play Store upload key.
// Falls back to the debug keystore if the file isn't present — that way local
// dev builds still work for contributors who don't have the production key.
val keystoreProperties = Properties()
val keystorePropsFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropsFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropsFile))
}

android {
    namespace = "com.bbsynthetics.catalog_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications needs Java 8+ time APIs desugared so the
        // daily reminder works on older Android versions.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.bbsynthetics.catalog_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8/resource-shrinking is OFF: with it on, R8 stripped the ML Kit
            // OCR engine and prices wouldn't read on Android. Off = reliable
            // OCR. (proguard-rules.pro keeps comprehensive ML Kit rules ready
            // for whenever shrinking is re-enabled AND verified in future.)
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Required by flutter_local_notifications when core library desugaring is on.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
