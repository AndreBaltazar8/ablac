package dev.ablac.llvm

import org.bytedeco.javacpp.PointerPointer
import org.bytedeco.llvm.LLVM.LLVMBasicBlockRef
import org.bytedeco.llvm.LLVM.LLVMModuleRef
import org.bytedeco.llvm.LLVM.LLVMTypeRef
import org.bytedeco.llvm.LLVM.LLVMValueRef
import org.bytedeco.llvm.global.LLVM
import org.bytedeco.llvm.global.LLVM.*

fun LLVMModuleRef.addFunction(
    name: String,
    returnType: LLVMTypeRef,
    args: Array<LLVMTypeRef>,
    isVarArg: Boolean = false
): LLVMValueRef = LLVM.LLVMAddFunction(
    this,
    name,
    LLVMFunctionType(returnType, PointerPointer(*args), args.size, isVarArg.toInt())
)

fun LLVMValueRef.setLinkage(linkage: Int) = apply {
    LLVMSetLinkage(this, linkage)
}

fun LLVMValueRef.setName(name: String) = apply {
    LLVMSetValueName(this, name)
}

fun LLVMValueRef.appendBasicBlock(name: String, block: LLVMBasicBlockRef.() -> Unit) = apply {
    LLVMAppendBasicBlock(this, name).block()
}

private fun Boolean.toInt(): Int = if (this) 1 else 0
