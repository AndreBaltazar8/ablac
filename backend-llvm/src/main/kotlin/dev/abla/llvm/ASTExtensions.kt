package dev.abla.llvm

import dev.abla.common.Symbol
import dev.abla.common.SymbolTable
import dev.abla.common.toType
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
fun Type.llvmType(symbolTable: SymbolTable): LLVMTypeRef = when {
    this is FunctionType -> LLVMPointerType(
        LLVMFunctionType(
            returnType.llvmType(symbolTable),
            PointerPointer(*parameters.map { it.type.llvmType(symbolTable) }.toTypedArray()),
            parameters.size,
            0
        ),
        0
    )
    this is UserType && this.identifier == "array" ->
        LLVMPointerType((if (types.size == 1) types[0] else UserType.Any).llvmType(symbolTable), 0)
    this == UserType.String -> LLVMPointerType(LLVMInt8Type(), 0)
    this == UserType.Int -> LLVMInt32Type()
    this == UserType.Void -> LLVMVoidType()
    this == UserType.Bool -> LLVMInt1Type()
    this == UserType.Any -> LLVMPointerType(LLVMInt64Type(), 0)
    this is PointerType -> LLVMPointerType(LLVMInt64Type(), 0)
    this is UserType -> {
        val symbol = symbolTable.find(identifier)
        if (symbol == null)
            throw Exception("Unknown user type to llvm type conversion ${this.toHuman()}")
        else
            LLVMPointerType((symbol as Symbol.Class).node.struct, 0)
    }
    else -> throw Exception("Unknown type to llvm type conversion ${this.toHuman()}")
}
var ClassDeclaration.struct: LLVMTypeRef? by BackingField.nullable()
var ClassDeclaration.constructorFunction: LLVMValueRef? by BackingField.nullable()
var MemberAccess.returnClass: Boolean by BackingField { false }

