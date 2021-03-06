package dev.abla.llvm

import dev.abla.common.SymbolTable
import dev.abla.language.nodes.Type
import org.bytedeco.llvm.LLVM.LLVMBasicBlockRef
import org.bytedeco.llvm.LLVM.LLVMValueRef
import java.util.*

class GeneratorContext {
    val blocks = Stack<CodeGenBlock>()
    val values = Stack<Value>()

    val topBlock: CodeGenBlock get() = blocks.peek()
    val topValue: Value get() = values.peek()
    val topValuePop: Value
        get() = values.removeAt(values.lastIndex)

    fun pushBlock(block: LLVMBasicBlockRef, table: SymbolTable) =
        CodeGenBlock(block, table, blocks.firstOrNull()).also {
            blocks.push(it)
        }

    inline fun withBlock(block: LLVMBasicBlockRef, table: SymbolTable, onBlock: CodeGenBlock.() -> Unit) =
        CodeGenBlock(block, table, blocks.firstOrNull()).also {
            blocks.push(it)
            it.onBlock()
            popBlock(true)
        }

    inline fun pushReplaceBlock(block: LLVMBasicBlockRef, table: SymbolTable, onBlock: CodeGenBlock.() -> Unit = {}) {
        blocks.peek().let {
            it.block = block
            it.table = table
            it.wasReplaced = true
            it.onBlock()
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

    data class Value(val type: Type, val ref: LLVMValueRef)
}