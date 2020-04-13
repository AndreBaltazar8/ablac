plugins {
    `kotlin-dsl`
}

repositories {
    jcenter()
}

dependencies {
    implementation(gradleApi())
    implementation(gradleKotlinDsl())
}
