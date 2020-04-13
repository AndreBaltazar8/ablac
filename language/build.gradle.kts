plugins {
    kotlin("jvm")
    kotlin("kapt")

    `java-library`
}

dependencies {
    kapt(project(":processor"))
    compileOnly(project(":annotations"))

    implementation(platform(Dependencies.KOTLIN_BOM))
    implementation(Dependencies.KOTLIN_STDLIB)
    implementation(Dependencies.KOIN)
    implementation(Dependencies.KOTLINX_COROUTINES_CORE)

    implementation(project(":grammar"))
    implementation(project(":utils"))

    testImplementation(Dependencies.KOTLIN_TEST)
    testImplementation(Dependencies.KOTLIN_TEST_JUNIT)
}
