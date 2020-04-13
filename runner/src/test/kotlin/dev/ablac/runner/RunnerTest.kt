package dev.ablac.runner

import org.koin.core.context.startKoin
import org.koin.core.context.stopKoin
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test

class RunnerTest {
    @BeforeTest
    fun before() {
        startKoin {
            printLogger()
            modules(modules)
        }
    }

    @AfterTest
    fun tearDown() {
        stopKoin()
    }

    @Test
    fun testFunctionDeclaration() = runResourceFile("examples/fun_decl.ab")

    private fun runResourceFile(file: String) {
        //System.setIn(javaClass.classLoader.getResourceAsStream(file))
        Runner().run(arrayOf(javaClass.classLoader.getResource(file)!!.path))
    }
}