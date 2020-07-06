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
    fun testMisc() = runResourceFile("examples/test_misc.ab") {
        println(it)
    }

    @Test
    fun testArrays() = runResourceFile("examples/test_arrays.ab") {
        println(it)
        assert(it.contains("%1 = getelementptr i32, i32* %0, i32 0"))
        assert(it.contains("store i32 5, i32* %1"))
        assert(it.contains("%2 = add i32 %1, 20"))
    }

    @Test
    fun testAPI() = runResourceFile("examples/test_api.ab") {
        println(it)
    }

    @Test
    fun testPackets() = runResourceFile("examples/test_packets.ab") {
        println(it)
    }

    @Test
    fun testGenericTypeFunctions() = runResourceFile("examples/test_generic_type_functions.ab") {
        println(it)
    }

    @Test
    fun testClassDeclaration() = runResourceFile("examples/test_class_declaration.ab") {
        println(it)
        assert(it.contains("%Chicken = type { %Chicken_vtable_type*, i32, i32, i32, i8* }"))
        assert(it.contains("%0 = call %Chicken* @\"Chicken%%constructor\"()"))
    }

    @Test
    fun testCompilerContext() = runResourceFile("examples/test_compiler_context.ab") {
        println(it)
        assert(it.indexOf("%2 = add i32 %0, 5") == -1)
        assert(it.contains("%4 = add i32 %2, 20"))
    }

    @Test
    fun testFunctions() = runResourceFile("examples/test_functions.ab") {
        println(it)
        assert(it.contains("declare i32 @printf(i8*)"))
        assert(it.contains("call void @voidReturn()"))
    }

    @Test
    fun testBuiltInTypeFunctions() = runResourceFile("examples/test_builtin_type_functions.ab") {
        println(it)
    }

    @Test
    fun testFunctionLiterals() = runResourceFile("examples/test_function_literals.ab") {
        println(it)
        assert(it.contains("%0 = call i32 @funliteral"))
        assert(it.contains("define i32 @funliteral"))
    }

    @Test
    fun testOperators() = runResourceFile("examples/test_operators.ab") {
        println(it)
        assert(it.contains("%3 = sdiv i32 8, %2"))
        assert(it.contains("%1 = mul i32 %0, 2"))
        assert(it.contains("%3 = icmp sgt i32 %2, 2"))
    }

    @Test
    fun testStrings() = runResourceFile("examples/test_strings.ab") {
        println(it)
        assert(it.contains("private unnamed_addr constant [5 x i8] c\" ok\\0A\\00\", align 1"))

        assert(it.contains("private unnamed_addr constant [8 x i8] c\"fact(4)\\00\", align 1"))
        assert(it.contains("private unnamed_addr constant [28 x i8] c\"expecting fact(4) to be 24\\0A\\00\", align 1"))

        assert(it.contains("private unnamed_addr constant [10 x i8] c\"hello hi\\0A\\00\", align 1"))
    }

    @Test
    fun testTrailingLambdas() = runResourceFile("examples/test_trailing_lambda.ab") {
        println(it)
        assert(it.contains("%3 = call i32 %2()"))
        assert(it.contains("%0 = call i32 @wrap(i32 ()* @funliteral"))
    }

    @Test
    fun testVariable() = runResourceFile("examples/test_variable.ab") {
        println(it)
        assert(it.contains("%0 = alloca i32"))
        assert(it.contains("store i32 1, i32* %0"))
        assert(it.contains("%1 = alloca i32"))
        assert(it.contains("store i32 2, i32* %1"))
        assert(it.contains("%2 = load i32, i32* %0"))
        assert(it.contains("%3 = load i32, i32* %1"))
        assert(it.contains("%4 = add i32 %2, %3"))
    }

    @Test
    fun testWhile() = runResourceFile("examples/test_while.ab") {
        println(it)
        assert(it.contains("br i1 %2, label %while_block, label %while_cont_block"))
        assert(it.contains("while_block:"))
        assert(it.contains("br label %while_condition_block"))
        assert(it.contains("while_cont_block:"))
    }

    @Test
    fun testWhen() = runResourceFile("examples/test_when.ab") {
        println(it)
        assert(it.contains("icmp eq i32 %2, 1"))
        assert(it.contains("icmp eq i32 %2, 2"))

        assert(it.contains("icmp eq i32 %1, 10"))
        assert(it.contains("icmp eq i32 %1, 20"))
        assert(it.contains("icmp eq i32 %1, 5"))
    }

    @Test
    fun testFiles() = runResourceFile("examples/test_files.ab") {
        println(it)
    }

    @Test
    fun testInterface() = runResourceFile("examples/test_interface.ab") {
        println(it)
    }

    @Test
    fun testNull() = runResourceFile("examples/test_null.ab") {
        println(it)
    }

    private fun runResourceFile(file: String, verify: (moduleIR: String) -> Unit = {}) {
        //System.setIn(javaClass.classLoader.getResourceAsStream(file))
        Runner().run(arrayOf(javaClass.classLoader.getResource(file)!!.path))
        val llvmCodeGenerator = get<ILLVMCodeGenerator>()
        verify(llvmCodeGenerator.getModuleIR())
    }
}