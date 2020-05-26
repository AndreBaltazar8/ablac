package dev.abla.common

import dev.abla.language.nodes.*
import dev.abla.language.positionZero
import dev.abla.utils.BackingField

var File.symbolTable: SymbolTable? by BackingField.nullable()
var FunctionDeclaration.symbolTable: SymbolTable? by BackingField.nullable()
var ClassDeclaration.symbolTable: SymbolTable? by BackingField.nullable()
var Block.symbolTable: SymbolTable? by BackingField.nullable()
var Node.symbol: Symbol<*>? by BackingField.nullable()
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

// TODO: need to calculate correct receiver and first parameter
fun FunctionDeclaration.toType(): Type =
    FunctionType(parameters, returnType ?: UserType.Void, null, positionZero)

// TODO: need to calculate correct parent
fun ClassDeclaration.toType(): Type = UserType(name, arrayOf(), null, positionZero)
