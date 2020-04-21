package dev.ablac.llvm

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
                if (generatorContext.values.isNotEmpty())
                    LLVMBuildRet(builder, generatorContext.topValue)
                else
                    LLVMBuildRet(builder, LLVMConstInt(LLVMInt32Type(), 1, 0))
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
        functionCall.primaryExpression.accept(this)
        val node = generatorContext.topValuePop
        val builder = LLVMCreateBuilder()
        LLVMPositionBuilderAtEnd(builder, currentBlock.block)

        val args = functionCall.arguments.map {
            it.value.accept(this)
            generatorContext.topValuePop
        }.toTypedArray()

        val value = LLVMBuildCall(
            builder,
            node,
            PointerPointer(*args),
            functionCall.arguments.size,
            "${node.hashCode()}()"
        )
        generatorContext.values.push(value)
    }

    override suspend fun visit(integer: Integer) {
        generatorContext.values.push(LLVMConstInt(LLVMInt32Type(), integer.number.toLong(), 0))
        super.visit(integer)
    }

    override suspend fun visit(functionLiteral: FunctionLiteral) {
        val numValues = generatorContext.values.size
        val block = functionLiteral.llvmBlock!!
        val currentBlock = generatorContext.pushBlock(block, generatorContext.topBlock.table)
        functionLiteral.block.accept(this)
        if (!currentBlock.hasReturned) {
            // CHECK FOR TYPE

            currentBlock.block.also {
                val builder = LLVMCreateBuilder()
                LLVMPositionBuilderAtEnd(builder, it)
                if (generatorContext.values.isNotEmpty())
                    LLVMBuildRet(builder, generatorContext.topValue)
                else
                    LLVMBuildRet(builder, LLVMConstInt(LLVMInt32Type(), 1, 0))
            }
            currentBlock.hasReturned = true
        }
        repeat(generatorContext.values.size - numValues) {
            generatorContext.values.pop()
        }
        generatorContext.popBlock(false)
        generatorContext.values.push(functionLiteral.llvmValue!!)
    }
}