// The Android app. `./gradlew assembleDebug` builds it, `./gradlew test` runs the unit tests;
// scripts/run-android.sh builds, installs and launches it on an emulator.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "maple-factory-android"
include(":app")
