group = "dev.fluttercommunity.plus.share"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.2.0"

    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.12.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}


plugins {
    id("com.android.library")
}

// This plugin does not apply the Kotlin Gradle Plugin: AGP 9 compiles the Kotlin
// sources in src/main/kotlin itself (built-in Kotlin) and rejects KGP next to it;
// a consumer that runs with built-in Kotlin off gets KGP applied by Flutter's
// plugin handler, which does that for every plugin that declares none.

project.extensions.configure(org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension::class.java) {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

android {
    namespace = "dev.fluttercommunity.plus.share"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 21
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    lint {
        disable.add("InvalidPackage")
    }

    dependencies {
        implementation("androidx.core:core-ktx:1.16.0")
        implementation("androidx.annotation:annotation:1.9.1")
        implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    }
}
