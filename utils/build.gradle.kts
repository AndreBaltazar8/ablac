plugins {
    kotlin("jvm")

    `java-library`
}

dependencies {
    commonDependencies()
    implementation(Dependencies.KOIN)
    implementation(Dependencies.KOTLINX_COROUTINES_CORE)
}
