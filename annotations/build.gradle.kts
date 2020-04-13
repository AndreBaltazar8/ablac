plugins {
    kotlin("jvm")

    `java-library`
}

dependencies {
    implementation(platform(Dependencies.KOTLIN_BOM))
    implementation(Dependencies.KOTLIN_STDLIB)
    testImplementation(Dependencies.KOTLIN_TEST)
    testImplementation(Dependencies.KOTLIN_TEST_JUNIT)
}
