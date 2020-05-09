package dev.abla.llvm

import dev.abla.common.*
import org.bytedeco.llvm.LLVM.LLVMModuleRef
import org.bytedeco.llvm.global.LLVM.*

interface ILLVMCodeGenerator : ICodeGenerator {
    fun getModuleIR(): String
}

class LLVMCodeGenerator : ILLVMCodeGenerator {
    private lateinit var module: LLVMModuleRef

    override suspend fun generateCode(
        compilationUnits: Collection<CompilationUnit>,
        codeGenParameters: CodeGenParameters
    ) {
        module = LLVMModuleCreateWithName("main_module")
        LLVMSetTarget(module, LLVMGetDefaultTargetTriple())

        compilationUnits.forEach { it.file.accept(LLVMTypeGenerator(module)) }
        compilationUnits.forEach { it.file.accept(CodeGeneratorVisitor(module)) }

        LLVMWriteBitcodeToFile(module, "${codeGenParameters.outputName}.bc")
    }

    override fun getModuleIR(): String = LLVMPrintModuleToString(module).string
}