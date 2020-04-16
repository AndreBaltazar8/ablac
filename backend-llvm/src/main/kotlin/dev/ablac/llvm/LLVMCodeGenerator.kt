package dev.ablac.llvm

import dev.ablac.common.*
import dev.ablac.language.ASTVisitor
import dev.ablac.language.nodes.*
import org.bytedeco.javacpp.PointerPointer
import org.bytedeco.llvm.LLVM.LLVMBasicBlockRef
import org.bytedeco.llvm.LLVM.LLVMModuleRef
import org.bytedeco.llvm.LLVM.LLVMTypeRef
import org.bytedeco.llvm.LLVM.LLVMValueRef
import org.bytedeco.llvm.global.LLVM.*
import java.util.*

interface ILLVMCodeGenerator : ICodeGenerator

class LLVMCodeGenerator : ILLVMCodeGenerator, ASTVisitor() {
    private lateinit var module: LLVMModuleRef
    private var blocks = Stack<CodeGenBlock>()
    private var values = Stack<LLVMValueRef>()

    override suspend fun generateCode(compilationUnits: Collection<CompilationUnit>) {
        module = LLVMModuleCreateWithName("main_module")
        val llvmTypeGenerator = LLVMTypeGenerator(module)
        compilationUnits.forEach { it.file.accept(llvmTypeGenerator) }
        compilationUnits.forEach { it.file.accept(this) }
        LLVMDumpModule(module)
    }

    private fun pushBlock(block: LLVMBasicBlockRef, table: SymbolTable) =
        CodeGenBlock(block, table, blocks.firstOrNull()).also {
            blocks.push(it)
        }

    private fun pushReplaceBlock(block: LLVMBasicBlockRef, table: SymbolTable) {
        blocks.peek().let {
            it.block = block
            it.table = table
            it.wasReplaced = true
        }
    }

    private fun popBlock(allowReplace: Boolean) {
        val block = blocks.pop()
        if (allowReplace && block.wasReplaced && blocks.isNotEmpty()) {
            blocks.peek().also {
                it.block = block.block
                it.wasReplaced = true
            }
        }
    }

    override suspend fun visit(functionDeclaration: FunctionDeclaration) {
        val function = functionDeclaration.llvmValue!!
        if (functionDeclaration.name == "main") {
            function.setName("%%_main")

            module.addFunction("main", LLVMInt16Type(), arrayOf())
                .setLinkage(LLVMExternalLinkage)
                .appendBasicBlock("entry") {
                    val builder = LLVMCreateBuilder()
                    LLVMPositionBuilderAtEnd(builder, this)
                    val call = LLVMBuildCall(
                        builder,
                        functionDeclaration.llvmValue!!,
                        PointerPointer<LLVMTypeRef>(),
                        0,
                        "main()"
                    )
                    LLVMBuildRet(builder, call)
                }
        }

        val block = functionDeclaration.llvmBlock!!
        val symbolTable = functionDeclaration.symbolTable!!
        val currentBlock = pushBlock(block, symbolTable)

        super.visit(functionDeclaration)

        if (!currentBlock.hasReturned) {
            // CHECK FOR TYPE

            currentBlock.block.also {
                val builder = LLVMCreateBuilder()
                LLVMPositionBuilderAtEnd(builder, it)
                LLVMBuildRet(builder, values.peek())
            }
            currentBlock.hasReturned = true
        }

        values.clear()
        popBlock(false)
    }

    override suspend fun visit(functionCall: FunctionCall) {
        val currentBlock = blocks.peek()
        val function = currentBlock.table.find(
            (functionCall.primaryExpression as IdentifierExpression).identifier
        ) as Symbol.Function
        val builder = LLVMCreateBuilder()
        LLVMPositionBuilderAtEnd(builder, currentBlock.block)
        val value = LLVMBuildCall(
            builder,
            function.functionDeclaration.llvmValue,
            PointerPointer<LLVMTypeRef>(),
            0,
            "${function.name}()"
        )
        values.push(value)
    }

    override suspend fun visit(integer: Integer) {
        values.push(LLVMConstInt(LLVMInt32Type(), integer.number.toLong(), 0))
        super.visit(integer)
    }
}