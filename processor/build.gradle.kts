plugins {
    kotlin("jvm")
    kotlin("kapt")

    `java-library`
}

dependencies {
    commonDependencies()
    implementation(Dependencies.KOTLIN_POET)
    implementation(Dependencies.AUTO_SERVICE)
    implementation(kotlin("compiler"))

    implementation(project(":annotations"))

    kapt(Dependencies.AUTO_SERVICE)
}
