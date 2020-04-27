package dev.abla.llvm

import org.bytedeco.javacpp.PointerPointer
import org.bytedeco.llvm.LLVM.LLVMBasicBlockRef
import org.bytedeco.llvm.LLVM.LLVMModuleRef
import org.bytedeco.llvm.LLVM.LLVMTypeRef
import org.bytedeco.llvm.LLVM.LLVMValueRef
import org.bytedeco.llvm.global.LLVM.*

fun LLVMModuleRef.addFunction(
    name: String,
    returnType: LLVMTypeRef,
    args: Array<LLVMTypeRef>,
    isVarArg: Boolean = false
): FunctionLLVM {
    val type = LLVMFunctionType(returnType, PointerPointer(*args), args.size, isVarArg.toInt())
    val function = LLVMAddFunction(this, name, type)
    return FunctionLLVM(type, function)
}

fun LLVMValueRef.setLinkage(linkage: Int) = apply {
    LLVMSetLinkage(this, linkage)
}

fun LLVMValueRef.setName(name: String) = apply {
    LLVMSetValueName(this, name)
}

fun LLVMValueRef.appendBasicBlock(name: String, block: LLVMBasicBlockRef.() -> Unit) = apply {
    LLVMAppendBasicBlock(this, name).block()
}

fun LLVMModuleRef.registerTypeVtable(
    name: String,
    methodsTypes: Array<LLVMTypeRef>,
    methods: Array<LLVMValueRef>
): LLVMTypeRef {
    val vTableName = "${name}_vtable_type"
    val struct = LLVMStructCreateNamed(LLVMGetGlobalContext(), vTableName)
    LLVMStructSetBody(struct, PointerPointer(*methodsTypes), methodsTypes.size, 0)
    LLVMAddGlobal(this, struct, vTableName).apply {
        LLVMSetInitializer(this, LLVMConstStruct(PointerPointer(*methods), methods.size, 0))
        setLinkage(LLVMGhostLinkage)
    }
    return struct
}




private fun Boolean.toInt(): Int = if (this) 1 else 0
