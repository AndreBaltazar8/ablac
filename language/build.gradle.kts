plugins {
    kotlin("jvm")

    `java-library`
}

projectCommon()

dependencies {
    implementation(Dependencies.KOIN)
    implementation(Dependencies.KOTLINX_COROUTINES_CORE)

    implementation(project(":grammar"))
    implementation(project(":utils"))
}
