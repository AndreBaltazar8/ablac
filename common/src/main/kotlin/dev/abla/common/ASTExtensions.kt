package dev.abla.common

import dev.abla.language.nodes.*
import dev.abla.utils.BackingField

var File.symbolTable: SymbolTable? by BackingField.nullable()
var FunctionDeclaration.symbolTable: SymbolTable? by BackingField.nullable()
var WhileStatement.symbolTable: SymbolTable? by BackingField.nullable()
var IfElseExpression.ifSymbolTable: SymbolTable? by BackingField.nullable()
var IfElseExpression.elseSymbolTable: SymbolTable? by BackingField.nullable()
var Node.symbol: Symbol<*>? by BackingField.nullable()
var Expression.returnForAssignment: Boolean by BackingField { false }
