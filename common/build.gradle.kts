plugins {
    kotlin("jvm")
}

dependencies {
    commonDependencies()

    implementation(Dependencies.KOIN)
    implementation(Dependencies.KOTLINX_COROUTINES_CORE)

    implementation(project(":language"))
    implementation(project(":utils"))
}
