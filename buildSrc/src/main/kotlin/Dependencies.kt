import org.gradle.api.Project
import org.gradle.api.tasks.testing.Test
import org.gradle.kotlin.dsl.*

fun Project.projectCommon() {
    dependencies {
        commonDependencies()
    }

    tasks.findByName("test")?.let { task ->
        val test = task as Test
        test.useJUnitPlatform()
    }
}

fun DependencyHandlerScope.commonDependencies() {
    "implementation"(platform(Dependencies.KOTLIN_BOM))
    "implementation"(Dependencies.KOTLIN_STDLIB)
    "testImplementation"(Dependencies.JUNIT_JUPITER)
}

object Dependencies {
    const val KOTLIN_VERSION = "1.3.71"

    const val KOTLIN_BOM = "org.jetbrains.kotlin:kotlin-bom"
    const val KOTLIN_STDLIB = "org.jetbrains.kotlin:kotlin-stdlib"
    const val KOTLIN_TEST = "org.jetbrains.kotlin:kotlin-test"
    const val KOTLIN_TEST_JUNIT = "org.jetbrains.kotlin:kotlin-test-junit5"
    const val KOTLINX_COROUTINES_CORE = "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.3.5"

    const val KOTLIN_POET = "com.squareup:kotlinpoet:1.5.0"
    const val AUTO_SERVICE = "com.google.auto.service:auto-service:1.0-rc6"

    const val ANTLR = "org.antlr:antlr4:4.8-1"
    const val KOIN = "org.koin:koin-core:2.1.5"
    const val LLVM = "org.bytedeco:llvm-platform:10.0.0-1.5.3"

    const val JUNIT_JUPITER = "org.junit.jupiter:junit-jupiter:5.6.2"
}
