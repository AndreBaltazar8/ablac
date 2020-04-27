package dev.abla.llvm

import dev.abla.language.nodes.Node
import dev.abla.utils.BackingField
import org.bytedeco.llvm.LLVM.LLVMBasicBlockRef
import org.bytedeco.llvm.LLVM.LLVMValueRef

var Node.llvmValue: LLVMValueRef? by BackingField.nullable()
var Node.llvmBlock: LLVMBasicBlockRef? by BackingField.nullable()
