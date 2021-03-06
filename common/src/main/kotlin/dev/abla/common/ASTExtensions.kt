package dev.abla.common

import dev.abla.language.nodes.*
import dev.abla.language.positionZero
import dev.abla.utils.BackingField

var File.symbolTable: SymbolTable? by BackingField.nullable()
var FunctionDeclaration.symbolTable: SymbolTable? by BackingField.nullable()
var ClassDeclaration.symbolTable: SymbolTable? by BackingField.nullable()
var FunctionLiteral.symbolTable: SymbolTable? by BackingField.nullable()
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
        } ?:parameters.toTypedArray<Parameter>(),
        inferredReturnType ?: UserType.Void,
        receiver,
        positionZero
    )

// TODO: need to calculate correct parent
fun ClassDeclaration.toType(): UserType = UserType(name, arrayOf(), null, positionZero)
val FunctionDeclaration.inferredReturnType: Type?
    get() = returnType ?: if (isLambda) block?.returnType else null
val PropertyDeclaration.inferredType: Type?
    get() = type ?: value!!.inferredType
val Expression.inferredType: Type?
    get() = when (this) {
        is IfElseExpression -> if (isExpression) ifBody.returnType else null
        is FunctionLiteral -> FunctionType(arrayOf(), UserType.Int, null, position)
        is NullLiteral -> UserType.Void
        is Integer -> UserType.Int
        is StringLiteral -> UserType.String
        is ArrayLiteral -> if (elements.isNotEmpty())
            UserType("array", arrayOf(elements[0].inferredType!!))
        else
            throw Exception("Cannot infer array type")
        is FunctionCall -> when(val returnType = expression.inferredType) {
            is FunctionType -> returnType.returnType
            null -> UserType.Void // TODO: remove when MemberAccess infer is fixed
            else -> throw Exception("Call on non function type?")
        }
        is IdentifierExpression -> when (val node = symbolLazy!!.value!!.node) {
            is FunctionDeclaration -> FunctionType(
                node.parameters.toTypedArray(),
                node.inferredReturnType ?: UserType.Void,
                node.inferredReturnType,
                node.position
            )
            is PropertyDeclaration -> node.inferredType
            is ClassDeclaration -> FunctionType(
                node.constructor?.mappedParameters?.toTypedArray() ?: arrayOf(),
                node.toType(),
                null,
                node.position
            )
            is Parameter -> node.type
            else -> throw Exception("Conversion not implemented")
        }
        is BinaryOperation -> rhs.inferredType
        is CompileExec -> expression.inferredType
        is IndexAccess -> (expression.inferredType as UserType).types[0]
        is Assignment -> rhs.inferredType
        is MemberAccess -> null // TODO: Actually infer this type
        else -> throw Exception("Conversion not implemented")
    }
val Block.returnType: Type?
    get() = statements.lastOrNull { it is Expression }?.let { (it as Expression).inferredType }
val IfElseExpression.isExpression: Boolean
    get() = elseBody.let { elseBody -> elseBody != null && ifBody.returnType.let { it != null && it == elseBody.returnType }}
var FunctionLiteral.forcedReturnType: Type? by BackingField.nullable()
val ClassConstructor.mappedParameters: List<Parameter>
    get() = parameters.map {
        when (it) {
            is Parameter -> it
            is PropertyDeclaration -> Parameter(it.name, it.inferredType!!, it.position)
            else -> throw Exception("Unknown parameter type ${it.javaClass.simpleName}")
        }
    }