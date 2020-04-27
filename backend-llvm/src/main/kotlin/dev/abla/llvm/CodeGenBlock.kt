package dev.abla.llvm

import dev.abla.common.SymbolTable
import org.bytedeco.llvm.LLVM.LLVMBasicBlockRef

class CodeGenBlock(var block: LLVMBasicBlockRef, var table: SymbolTable, var parent: CodeGenBlock?) {
    var hasReturned: Boolean = false
    var wasReplaced: Boolean = false
}
