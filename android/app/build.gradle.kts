import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release-Signatur: erst android/key.properties (storeFile, storePassword,
// keyAlias, keyPassword), sonst die Umgebungsvariablen HAVEN_KEYSTORE,
// HAVEN_KEYSTORE_PASSWORD, HAVEN_KEY_ALIAS und HAVEN_KEY_PASSWORD. Fehlt beides,
// signiert der Release-Build mit dem Debug-Schlüssel.
val keyProps = Properties()
val keyPropsFile = rootProject.file("key.properties")
if (keyPropsFile.exists()) {
    keyPropsFile.inputStream().use { keyProps.load(it) }
}

fun signingValue(prop: String, env: String): String? =
    (if (keyPropsFile.exists()) keyProps.getProperty(prop) else System.getenv(env))
        ?.takeIf { it.isNotBlank() }

val releaseStore = signingValue("storeFile", "HAVEN_KEYSTORE")
val releaseStorePassword = signingValue("storePassword", "HAVEN_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "HAVEN_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "HAVEN_KEY_PASSWORD")
val hasReleaseSigning = releaseStore != null && releaseStorePassword != null &&
    releaseKeyAlias != null && releaseKeyPassword != null

android {
    namespace = "de.phiph.haven"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "de.phiph.haven"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStore!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("WARNUNG: Kein Release-Schlüssel (android/key.properties oder HAVEN_KEYSTORE*). Der Release-Build wird mit dem Debug-Schlüssel signiert und taugt nicht zur Veröffentlichung.")
                signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
    // Raum-Widget: Aktualisieren im Hintergrund.
    implementation("androidx.work:work-runtime-ktx:2.10.0")
}
