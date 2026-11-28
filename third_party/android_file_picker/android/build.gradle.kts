import com.android.build.api.dsl.LibraryExtension
import groovy.lang.GroovyObject
import org.gradle.kotlin.dsl.configure

group = "com.mr.flutter.plugin.filepicker"
version = "1.0-SNAPSHOT"

// Temporary workaround, not a permanent fix. Pinning an older AGP here while
// the consuming app applies a newer one through the `plugins` block is
// generally discouraged, this module didn't declare it until it broke
// `android.newDsl=false` projects with custom root level Gradle
// configuration (#2170). Flutter's own AGP 9 `newDsl` migration is still in
// progress (https://github.com/flutter/flutter/issues/180137); its interim
// compatibility shim doesn't appear to reliably reach plugin modules that
// don't declare their own classpath. Remove this block again once that
// migration lands upstream and `android.newDsl=false` is no longer needed.
buildscript {
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.5.2")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.8.22")
    }
}

rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

fun GroovyObject.intProperty(name: String): Int {
    val value = getProperty(name)
    return when (value) {
        is Number -> value.toInt()
        is String -> value.toInt()
        else -> error("Property '$name' is not an Int-compatible value: $value")
    }
}

apply(plugin = "com.android.library")
// This plugin does not apply the Kotlin Gradle Plugin. AGP 9 compiles the Kotlin
// sources in src/main/kotlin itself (built-in Kotlin, android.builtInKotlin=true)
// and rejects KGP next to it; a consumer that runs with built-in Kotlin off gets
// KGP applied by Flutter's plugin handler, which does that for every plugin that
// declares none.

val flutterExtension = extensions.getByName("flutter") as GroovyObject
val flutterCompileSdkVersion = flutterExtension.intProperty("compileSdkVersion")

configure<LibraryExtension> {
    compileSdk = flutterCompileSdkVersion
    namespace = "com.mr.flutter.plugin.filepicker"

    defaultConfig {
        minSdk = 21
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("proguard-rules.pro")
    }

    lint {
        disable += "InvalidPackage"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // The Kotlin target follows the Java one above; the extension is AGP 9's
    // built-in Kotlin, or the KGP Flutter applies for older consumers.
    project.extensions.configure(org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension::class.java) {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        }
    }
}

dependencies {
    add("implementation", "androidx.core:core:1.18.0")
    add("implementation", "androidx.core:core-ktx:1.18.0")
    add("implementation", "androidx.annotation:annotation:1.11.0")
    add("implementation", "androidx.lifecycle:lifecycle-runtime:2.10.0")

    add("testImplementation", "junit:junit:4.13.2")
    // The org.json in android.jar is a stub on the JVM, so unit tests need
    // the real implementation.
    add("testImplementation", "org.json:json:20260814")
}

