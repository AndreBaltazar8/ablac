package dev.abla.llvm

import dev.abla.common.*
import org.bytedeco.llvm.LLVM.LLVMModuleRef
import org.bytedeco.llvm.global.LLVM.*

interface ILLVMCodeGenerator : ICodeGenerator {
    fun getModuleIR(): String
}

class LLVMCodeGenerator : ILLVMCodeGenerator {
    private lateinit var lastIR: String

    override suspend fun generateCode(
        compilationUnits: Collection<CompilationUnit>,
        codeGenParameters: CodeGenParameters
    ) {
        val context = LLVMContextCreate()
        val module = LLVMModuleCreateWithNameInContext("main_module", context)
        LLVMSetTarget(module, LLVMGetDefaultTargetTriple())

        compilationUnits.forEach { it.file.accept(LLVMTypeGenerator(module)) }
        compilationUnits.forEach { it.file.accept(CodeGeneratorVisitor(module)) }

        LLVMWriteBitcodeToFile(module, "${codeGenParameters.outputName}.bc")

        lastIR = LLVMPrintModuleToString(module).string
        LLVMDisposeModule(module)
        LLVMContextDispose(context)
    }

    override fun getModuleIR(): String = lastIR
}