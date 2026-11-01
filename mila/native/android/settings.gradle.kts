import org.gradle.api.initialization.resolve.RepositoriesMode

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
        // Robolectric's ~200 MB SDK jar comes only from Google's mirror of Maven
        // Central: repo.maven.apache.org answers CI runners with 429 Too Many
        // Requests for it (mila-builds run 41287426560). Its sha256 is pinned
        // in gradle/verification-metadata.xml, so the source does not change
        // what is accepted.
        exclusiveContent {
            forRepository {
                maven {
                    name = "MavenCentralGoogleMirror"
                    url = uri("https://maven-central.storage-download.googleapis.com/maven2/")
                }
            }
            filter { includeModule("org.robolectric", "android-all-instrumented") }
        }
        mavenCentral()
    }
}

rootProject.name = "mila-native-android"
include(":app")
