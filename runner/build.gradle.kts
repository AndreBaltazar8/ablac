plugins {
    kotlin("jvm")

    application
}

dependencies {
    implementation(platform(Dependencies.KOTLIN_BOM))
    implementation(Dependencies.KOTLIN_STDLIB)
    implementation(Dependencies.KOIN)
    implementation(Dependencies.KOTLINX_COROUTINES_CORE)

    implementation(project(":grammar"))
    implementation(project(":language"))
    implementation(project(":frontend"))
    implementation(project(":backend"))
    implementation(project(":utils"))

    testImplementation(Dependencies.KOTLIN_TEST)
    testImplementation(Dependencies.KOTLIN_TEST_JUNIT)
}

application {
    mainClassName = "dev.ablac.runner.MainKt"
}
