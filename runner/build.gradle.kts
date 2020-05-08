plugins {
    kotlin("jvm")

    id("com.github.johnrengelman.shadow") version "5.2.0"
    application
}

projectCommon()

dependencies {
    implementation(Dependencies.KOIN)
    implementation(Dependencies.KOTLINX_COROUTINES_CORE)

    implementation(project(":grammar"))
    implementation(project(":language"))
    implementation(project(":frontend"))
    implementation(project(":backend-llvm"))
    implementation(project(":common"))
    implementation(project(":utils"))
}

application {
    mainClassName = "dev.abla.runner.MainKt"
}
