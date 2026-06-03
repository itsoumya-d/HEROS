// Root build script. The Android Gradle Plugin is declared here (apply false)
// and applied in app/build.gradle.kts. Keeping the app dependency-free (no
// AndroidX/Compose) minimises version coupling so it builds reliably in CI.
plugins {
    id("com.android.application") version "8.6.0" apply false
}
