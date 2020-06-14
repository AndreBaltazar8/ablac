package dev.abla.common

import dev.abla.language.nodes.*
import dev.abla.language.positionZero
import dev.abla.utils.BackingField

var File.symbolTable: SymbolTable? by BackingField.nullable()
var FunctionDeclaration.symbolTable: SymbolTable? by BackingField.nullable()
var ClassDeclaration.symbolTable: SymbolTable? by BackingField.nullable()
var Block.symbolTable: SymbolTable? by BackingField.nullable()
var PropertyDeclaration.symbolTable: SymbolTable? by BackingField.nullable()
var Node.symbol: Symbol<*>? by BackingField.nullable()
var Node.symbolLazy: Lazy<Symbol<*>?>? by BackingField.nullable()
var ClassDeclaration.symbol: Symbol.Class
    get() = Node::symbol.get(this) as Symbol.Class
    set(value) = Node::symbol.set(this, value)
var PropertyDeclaration.symbol: Symbol.Variable
    get() = Node::symbol.get(this) as Symbol.Variable
    set(value) = Node::symbol.set(this, value)
var FunctionDeclaration.symbol: Symbol.Function
    get() = Node::symbol.get(this) as Symbol.Function
    set(value) = Node::symbol.set(this, value)
var Expression.returnForAssignment: Boolean by BackingField { false }
var PropertyDeclaration.scope: Scope by BackingField { Scope.Global }
var FunctionDeclaration.receiverParameter: Parameter? by BackingField.nullable()

fun FunctionDeclaration.toType(): Type =
    FunctionType(
        receiverParameter?.let {
            arrayOf(it, *parameters.toTypedArray())
        } ?:parameters.toTypedArray(),
        returnType ?: block?.returnType ?: UserType.Void,
        receiver,
        positionZero
    )

// TODO: need to calculate correct parent
fun ClassDeclaration.toType(): Type = UserType(name, arrayOf(), null, positionZero)
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
        is IdentifierExpression -> when (val node = symbolLazy!!.value!!.node) {
            is FunctionDeclaration -> FunctionType(arrayOf(), node.returnType ?: node.block?.returnType ?: UserType.Void, node.returnType, node.position)
            is PropertyDeclaration -> node.inferredType
            is ClassDeclaration -> FunctionType(arrayOf(), node.toType(), null, node.position)
            is Parameter -> node.type
            else -> throw Exception("Conversion not implemented")
        }
        is BinaryOperation -> rhs.inferredType
        is CompilerExec -> expression.inferredType
        else -> throw Exception("Conversion not implemented")
    }
val Block.returnType: Type?
    get() = statements.lastOrNull { it is Expression }?.let { (it as Expression).inferredType }
val IfElseExpression.isExpression: Boolean
    get() = elseBody.let { elseBody -> elseBody != null && ifBody.returnType.let { it != null && it == elseBody.returnType }}
var FunctionLiteral.forcedReturnType: Type? by BackingField.nullable()