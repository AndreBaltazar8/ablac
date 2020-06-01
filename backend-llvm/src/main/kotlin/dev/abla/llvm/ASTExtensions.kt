package dev.abla.llvm

import dev.abla.language.nodes.*
import dev.abla.utils.BackingField
import org.bytedeco.javacpp.PointerPointer
import org.bytedeco.llvm.LLVM.LLVMBasicBlockRef
import org.bytedeco.llvm.LLVM.LLVMTypeRef
import org.bytedeco.llvm.LLVM.LLVMValueRef
import org.bytedeco.llvm.global.LLVM.*

var Node.llvmValue: LLVMValueRef? by BackingField.nullable()
var Node.llvmBlock: LLVMBasicBlockRef? by BackingField.nullable()
var IfElseExpression.llvmIfBlock: LLVMBasicBlockRef? by BackingField.nullable()
var IfElseExpression.llvmElseBlock: LLVMBasicBlockRef? by BackingField.nullable()
var IfElseExpression.llvmContBlock: LLVMBasicBlockRef? by BackingField.nullable()
var WhileStatement.llvmConditionBlock: LLVMBasicBlockRef? by BackingField.nullable()
var WhileStatement.llvmContBlock: LLVMBasicBlockRef? by BackingField.nullable()
val Type.llvmType: LLVMTypeRef
    get() = when {
        this is FunctionType -> LLVMPointerType(
            LLVMFunctionType(
                returnType.llvmType,
                PointerPointer(*parameters.map { it.type.llvmType }.toTypedArray()),
                parameters.size,
                0
            ),
            0
        )
        this == UserType.String -> LLVMPointerType(LLVMInt8Type(), 0)
        this == UserType.Int -> LLVMInt32Type()
        this == UserType.Void -> LLVMVoidType()
        this == UserType.Any -> LLVMPointerType(LLVMVoidType(), 0)
        else -> throw Exception("Unknown type to llvm type conversion ${this.toHuman()}")
    }
var ClassDeclaration.struct: LLVMTypeRef? by BackingField.nullable()
var ClassDeclaration.constructorFunction: LLVMValueRef? by BackingField.nullable()
var MemberAccess.returnClass: Boolean by BackingField { false }

