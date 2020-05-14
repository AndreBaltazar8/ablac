package dev.abla.common

import dev.abla.language.nodes.*
import dev.abla.language.positionZero
import dev.abla.utils.BackingField

var File.symbolTable: SymbolTable? by BackingField.nullable()
var FunctionDeclaration.symbolTable: SymbolTable? by BackingField.nullable()
var ClassDeclaration.symbolTable: SymbolTable? by BackingField.nullable()
var WhileStatement.symbolTable: SymbolTable? by BackingField.nullable()
var IfElseExpression.ifSymbolTable: SymbolTable? by BackingField.nullable()
var IfElseExpression.elseSymbolTable: SymbolTable? by BackingField.nullable()
var Node.symbol: Symbol<*>? by BackingField.nullable()
var Expression.returnForAssignment: Boolean by BackingField { false }
var PropertyDeclaration.scope: Scope by BackingField { Scope.Global }

// TODO: need to calculate correct receiver and first parameter
fun FunctionDeclaration.toType(): Type =
    FunctionType(parameters, returnType ?: UserType.Void, null, positionZero)

// TODO: need to calculate correct parent
fun ClassDeclaration.toType(): Type = UserType(name, arrayOf(), null, positionZero)
