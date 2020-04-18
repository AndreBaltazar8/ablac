package dev.ablac.llvm

import dev.ablac.common.Symbol
import dev.ablac.common.symbolTable
import dev.ablac.language.ASTVisitor
import dev.ablac.language.nodes.*
import org.bytedeco.javacpp.PointerPointer
import org.bytedeco.llvm.LLVM.LLVMModuleRef
import org.bytedeco.llvm.LLVM.LLVMTypeRef
import org.bytedeco.llvm.global.LLVM

class CodeGeneratorVisitor(private val module: LLVMModuleRef) : ASTVisitor() {
    private val generatorContext = GeneratorContext()

    override suspend fun visit(functionDeclaration: FunctionDeclaration) {
        val function = functionDeclaration.llvmValue!!
        if (functionDeclaration.name == "main") {
            function.setName("%%_main")

            module.addFunction("main", LLVM.LLVMInt16Type(), arrayOf())
                .setLinkage(LLVM.LLVMExternalLinkage)
                .appendBasicBlock("entry") {
                    val builder = LLVM.LLVMCreateBuilder()
                    LLVM.LLVMPositionBuilderAtEnd(builder, this)
                    val call = LLVM.LLVMBuildCall(
                        builder,
                        functionDeclaration.llvmValue!!,
                        PointerPointer<LLVMTypeRef>(),
                        0,
                        "main()"
                    )
                    LLVM.LLVMBuildRet(builder, call)
                }
        }

        val block = functionDeclaration.llvmBlock!!
        val symbolTable = functionDeclaration.symbolTable!!
        val currentBlock = generatorContext.pushBlock(block, symbolTable)

        super.visit(functionDeclaration)

        if (!currentBlock.hasReturned) {
            // CHECK FOR TYPE

            currentBlock.block.also {
                val builder = LLVM.LLVMCreateBuilder()
                LLVM.LLVMPositionBuilderAtEnd(builder, it)
                LLVM.LLVMBuildRet(builder, generatorContext.topValue)
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
        val function = currentBlock.table.find(
            (functionCall.primaryExpression as IdentifierExpression).identifier
        ) as Symbol.Function
        val builder = LLVM.LLVMCreateBuilder()
        LLVM.LLVMPositionBuilderAtEnd(builder, currentBlock.block)

        val args = functionCall.arguments.map {
            it.value.accept(this)
            generatorContext.topValuePop
        }.toTypedArray()

        val value = LLVM.LLVMBuildCall(
            builder,
            function.node.llvmValue,
            PointerPointer(*args),
            functionCall.arguments.size,
            "${function.name}()"
        )
        generatorContext.values.push(value)
    }

    override suspend fun visit(integer: Integer) {
        generatorContext.values.push(LLVM.LLVMConstInt(LLVM.LLVMInt32Type(), integer.number.toLong(), 0))
        super.visit(integer)
    }
}