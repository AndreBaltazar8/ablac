package dev.ablac.llvm

import dev.ablac.common.*
import dev.ablac.language.ASTVisitor
import dev.ablac.language.nodes.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.bytedeco.llvm.LLVM.LLVMModuleRef
import org.bytedeco.llvm.global.LLVM.*

interface ILLVMCodeGenerator : ICodeGenerator

class LLVMCodeGenerator : ILLVMCodeGenerator {
    private lateinit var module: LLVMModuleRef

    override suspend fun generateCode(compilationUnits: Collection<CompilationUnit>) {
        module = LLVMModuleCreateWithName("main_module")
        compilationUnits.forEach { it.file.accept(LLVMTypeGenerator(module)) }
        compilationUnits.forEach { it.file.accept(CodeGeneratorVisitor(module)) }
        LLVMDumpModule(module)
    }
}