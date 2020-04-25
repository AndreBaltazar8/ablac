package dev.ablac.llvm

import org.bytedeco.llvm.LLVM.LLVMTypeRef
import org.bytedeco.llvm.LLVM.LLVMValueRef

data class FunctionLLVM(val type: LLVMTypeRef, val valueRef: LLVMValueRef)
data class TypeScope(
    val name: String,
    val type: LLVMTypeRef,
    val fields: MutableList<LLVMTypeRef> = mutableListOf(),
    val methods: MutableList<FunctionLLVM> = mutableListOf()
)
