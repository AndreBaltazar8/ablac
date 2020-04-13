plugins {
    kotlin("jvm")
}

dependencies {
    implementation(platform(Dependencies.KOTLIN_BOM))
    implementation(Dependencies.KOTLIN_STDLIB)
    implementation(Dependencies.KOIN)
    implementation(Dependencies.KOTLINX_COROUTINES_CORE)

    implementation(project(":language"))
    implementation(project(":utils"))

    testImplementation(Dependencies.KOTLIN_TEST)
    testImplementation(Dependencies.KOTLIN_TEST_JUNIT)
}
