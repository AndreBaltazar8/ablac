package dev.ablac.llvm

import dev.ablac.common.Symbol
import dev.ablac.common.symbolTable
import dev.ablac.language.ASTVisitor
import dev.ablac.language.nodes.*
import org.bytedeco.javacpp.PointerPointer
import org.bytedeco.llvm.LLVM.LLVMModuleRef
import org.bytedeco.llvm.LLVM.LLVMTypeRef
import org.bytedeco.llvm.global.LLVM.*

class CodeGeneratorVisitor(private val module: LLVMModuleRef) : ASTVisitor() {
    private val generatorContext = GeneratorContext()

    override suspend fun visit(functionDeclaration: FunctionDeclaration) {
        if (functionDeclaration.isExtern)
            return

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
        val currentBlock = generatorContext.pushBlock(block, symbolTable)

        super.visit(functionDeclaration)

        if (!currentBlock.hasReturned) {
            // CHECK FOR TYPE

            currentBlock.block.also {
                val builder = LLVMCreateBuilder()
                LLVMPositionBuilderAtEnd(builder, it)
                LLVMBuildRet(builder, generatorContext.topValue)
            }
            currentBlock.hasReturned = true
        }

        generatorContext.values.clear()
        generatorContext.popBlock(false)
    }

    override suspend fun visit(identifierExpression: IdentifierExpression) {
        val currentBlock = generatorContext.topBlock
        val value = currentBlock.table.find(identifierExpression.identifier)
        generatorContext.values.push(value!!.node.llvmValue)
    }

    override suspend fun visit(functionCall: FunctionCall) {
        val currentBlock = generatorContext.topBlock
        val functionName = (functionCall.primaryExpression as IdentifierExpression).identifier
        val symbol = currentBlock.table.find(functionName) ?: throw Exception("Unknown function $functionName")
        val function = symbol as Symbol.Function

        val builder = LLVMCreateBuilder()
        LLVMPositionBuilderAtEnd(builder, currentBlock.block)

        val args = functionCall.arguments.map {
            it.value.accept(this)
            generatorContext.topValuePop
        }.toTypedArray()

        val value = LLVMBuildCall(
            builder,
            function.node.llvmValue,
            PointerPointer(*args),
            functionCall.arguments.size,
            "${function.name}()"
        )
        generatorContext.values.push(value)
    }

    override suspend fun visit(integer: Integer) {
        generatorContext.values.push(LLVMConstInt(LLVMInt32Type(), integer.number.toLong(), 0))
        super.visit(integer)
    }
}