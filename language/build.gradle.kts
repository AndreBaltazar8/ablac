plugins {
    kotlin("jvm")
    kotlin("kapt")

    `java-library`
}

projectCommon()

dependencies {
    kapt(project(":processor"))
    compileOnly(project(":annotations"))

    implementation(Dependencies.KOIN)
    implementation(Dependencies.KOTLINX_COROUTINES_CORE)

    implementation(project(":grammar"))
    implementation(project(":utils"))
}
