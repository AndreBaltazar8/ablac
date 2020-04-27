package dev.abla.llvm

import dev.abla.common.SymbolTable
import org.bytedeco.llvm.LLVM.LLVMBasicBlockRef
import org.bytedeco.llvm.LLVM.LLVMValueRef
import java.util.*

class GeneratorContext {
    val blocks = Stack<CodeGenBlock>()
    val values = Stack<LLVMValueRef>()

    val topBlock: CodeGenBlock get() = blocks.peek()
    val topValue: LLVMValueRef get() = values.peek()
    val topValuePop: LLVMValueRef
        get() = values.removeAt(values.lastIndex)

    fun pushBlock(block: LLVMBasicBlockRef, table: SymbolTable) =
        CodeGenBlock(block, table, blocks.firstOrNull()).also {
            blocks.push(it)
        }

    fun pushReplaceBlock(block: LLVMBasicBlockRef, table: SymbolTable) {
        blocks.peek().let {
            it.block = block
            it.table = table
            it.wasReplaced = true
        }
    }

    fun popBlock(allowReplace: Boolean) {
        val block = blocks.pop()
        if (allowReplace && block.wasReplaced && blocks.isNotEmpty()) {
            blocks.peek().also {
                it.block = block.block
                it.wasReplaced = true
            }
        }
    }
}