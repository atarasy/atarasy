plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "dev.atarasy.prototype"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.atarasy.prototype"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        resValue("string", "atarasy_recovery_notice_channel", providers.gradleProperty("atarasyRecoveryNoticeChannel").orElse("").get())
        resValue("string", "atarasy_move_target_name", providers.gradleProperty("atarasyMoveTargetName").orElse("").get())
        resValue("string", "atarasy_move_target_origin", providers.gradleProperty("atarasyMoveTargetOrigin").orElse("").get())
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures { compose = true }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    testOptions { unitTests.isReturnDefaultValues = true }
    lint { disable += setOf("AndroidGradlePluginVersion", "GradleDependency", "NewerVersionAvailable") }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.03.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.credentials:credentials:1.6.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.6.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
}
