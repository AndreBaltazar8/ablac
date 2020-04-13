plugins {
    kotlin("jvm")
    kotlin("kapt")

    `java-library`
}

dependencies {
    implementation(platform(Dependencies.KOTLIN_BOM))
    implementation(Dependencies.KOTLIN_STDLIB)
    implementation(Dependencies.KOTLIN_POET)
    implementation(Dependencies.AUTO_SERVICE)
    implementation(kotlin("compiler"))

    implementation(project(":annotations"))

    kapt(Dependencies.AUTO_SERVICE)

    testImplementation(Dependencies.KOTLIN_TEST)
    testImplementation(Dependencies.KOTLIN_TEST_JUNIT)
}
