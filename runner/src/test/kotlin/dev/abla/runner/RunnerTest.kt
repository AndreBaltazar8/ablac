package dev.abla.runner

import dev.abla.llvm.ILLVMCodeGenerator
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.koin.core.KoinComponent
import org.koin.core.context.startKoin
import org.koin.core.context.stopKoin
import org.koin.core.get

class RunnerTest : KoinComponent {
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
    fun testClassDeclaration() = runResourceFile("examples/test_class_declaration.ab") {
        assert(it.contains("%Chicken = type { %Chicken_vtable_type*, i32, i32, i32, i8* }"))
        assert(it.contains("%0 = call %Chicken* @\"Chicken%%constructor\"()"))
        println(it)
    }

    @Test
    fun testFunctions() = runResourceFile("examples/test_functions.ab") {
        assert(it.contains("call void @voidReturn()"))
    }

    @Test
    fun testFunctionLiterals() = runResourceFile("examples/test_function_literals.ab")

    @Test
    fun testOperators() = runResourceFile("examples/test_operators.ab")

    @Test
    fun testStrings() = runResourceFile("examples/test_strings.ab")

    @Test
    fun testTrailingLambdas() = runResourceFile("examples/test_trailing_lambda.ab")

    @Test
    fun testVariable() = runResourceFile("examples/test_variable.ab")

    @Test
    fun testWhile() = runResourceFile("examples/test_while.ab")

    private fun runResourceFile(file: String, verify: (moduleIR: String) -> Unit = {}) {
        //System.setIn(javaClass.classLoader.getResourceAsStream(file))
        Runner().run(arrayOf(javaClass.classLoader.getResource(file)!!.path))
        val llvmCodeGenerator = get<ILLVMCodeGenerator>()
        verify(llvmCodeGenerator.getModuleIR())
    }
}