plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.robotcortadora.cortadora_e7"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.robotcortadora.cortadora_e7"
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

// flutter_blue_plus_android 9.0.5 registra en cada build una tarea
// "flutterBluePlusLicensePing<Variante>" (license_ping.gradle) que manda a
// script.google.com el paquete, el nombre y la versión de la app, la versión
// del plugin y la fecha. Decisión del usuario (13/11/26): proyecto de uso
// educativo/personal sin fines de lucro (licencia FlutterBluePlus 1.6, §2/§5),
// con el envío DESACTIVADO. Solo afecta a este proyecto. `matching` es una
// colección viva: alcanza también a las tareas que el plugin crea después, en
// gradle.projectsEvaluated.
tasks.matching { it.name.startsWith("flutterBluePlusLicensePing") }.configureEach {
    enabled = false
}
