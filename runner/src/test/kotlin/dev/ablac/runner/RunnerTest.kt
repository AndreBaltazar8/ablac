package dev.ablac.runner

import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.koin.core.context.startKoin
import org.koin.core.context.stopKoin

class RunnerTest {
    @BeforeEach
    fun before() {
        startKoin {
            printLogger()
            modules(modules)
        }
    }

    @AfterEach
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