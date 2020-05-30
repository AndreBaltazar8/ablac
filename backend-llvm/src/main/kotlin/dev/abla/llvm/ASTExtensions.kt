package dev.abla.llvm

import dev.abla.common.symbol
import dev.abla.common.symbolLazy
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
val PropertyDeclaration.inferredType: Type?
    get() = type ?: value!!.inferredType
val Expression.inferredType: Type?
    get() = when (this) {
        is IfElseExpression -> if (isExpression) ifBody.returnType else null
        is FunctionLiteral -> FunctionType(arrayOf(), UserType.Int, null, position)
        is Integer -> UserType.Int
        is StringLiteral -> UserType.String
        is FunctionCall -> when(val returnType = expression.inferredType) {
            is FunctionType -> returnType.returnType
            else -> throw Exception("Call on non function type?")
        }
        is IdentifierExpression -> if (symbolLazy == null) throw Exception("Null $identifier") else when (val node = symbolLazy!!.value!!.node) {
            is FunctionDeclaration -> FunctionType(arrayOf(), node.returnType ?: UserType.Void, node.returnType, node.position)
            is PropertyDeclaration -> node.inferredType
            else -> throw Exception("Conversion not implemented")
        }
        is BinaryOperation -> rhs.inferredType
        else -> throw Exception("Conversion not implemented")
    }
val Block.returnType: Type?
    get() = statements.lastOrNull { it is Expression }?.let { (it as Expression).inferredType }
val IfElseExpression.isExpression: Boolean
    get() = elseBody.let { elseBody -> elseBody != null && ifBody.returnType.let { it != null && it == elseBody.returnType }}
var FunctionLiteral.forcedReturnType: Type? by BackingField.nullable()
