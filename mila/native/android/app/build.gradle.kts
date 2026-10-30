plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "dev.overalls.mila.nativeui"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.overalls.mila.nativeui"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    buildFeatures {
        compose = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.12.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.activity:activity-compose:1.12.0")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    debugImplementation("androidx.compose.ui:ui-tooling")

    testImplementation("junit:junit:4.13.2")
    // Android framework org.json methods are JVM stubs; use a real parser in
    // unit tests so bounded decoders are exercised instead of throwing.
    testImplementation("org.json:json:20250517")
    testImplementation("org.robolectric:robolectric:4.14.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
    // Drives system UI (BiometricPrompt/device credential) during emulator app-lock coverage.
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}

android {
    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

// Generated libraries stay under build/ and enter APKs through the JNI source set.
val rustRoot = rootProject.file("../../rust")
val localizationSource = rootProject.file("../../localization/catalogs")
val localizationOutput = layout.buildDirectory.dir("generated/mila-locales")
val generateMilaLocalization = tasks.register<Exec>("generateMilaLocalization") {
    inputs.dir(localizationSource)
    outputs.dir(localizationOutput)
    commandLine("python3", rootProject.file("../../localization/generate_catalogs.py").absolutePath,
        "--source", localizationSource.absolutePath, "--output", localizationOutput.get().asFile.absolutePath)
}
android.sourceSets.getByName("main").assets.srcDir(localizationOutput.get().asFile)
tasks.named("preBuild").configure { dependsOn(generateMilaLocalization) }
val rustJniOutput = layout.buildDirectory.dir("rust-jni")
val rustAbis = listOf("arm64-v8a", "armeabi-v7a", "x86_64")
android {
    ndkVersion = "28.2.13676358"
    defaultConfig {
        ndk { abiFilters += rustAbis }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    sourceSets.getByName("main").jniLibs.srcDir(rustJniOutput.get().asFile)
}

/**
 * @cc [owner:ghuntley,label:verification] mila-android-packaged-rust
 * APK assembly MUST build the Rust JNI library for every packaged ABI from the locked workspace.
 */
val buildRustJni = tasks.register<Exec>("buildRustJni") {
    workingDir(rustRoot)
    inputs.files(fileTree(rustRoot) { exclude("target/**") })
    // The Mila crates are members of the repository's root Cargo workspace,
    // whose manifest and single lock pin their dependencies (ADR-0273).
    inputs.files(rootProject.file("../../../Cargo.toml"), rootProject.file("../../../Cargo.lock"))
    outputs.dir(rustJniOutput)
    commandLine(
        listOf("cargo", "ndk", "--platform", "26") +
            rustAbis.flatMap { listOf("-t", it) } +
            listOf("-o", rustJniOutput.get().asFile.absolutePath,
                "build", "--locked", "--release", "-p", "mila-ffi")
    )
}
tasks.named("preBuild") { dependsOn(buildRustJni, generateMilaLocalization) }
