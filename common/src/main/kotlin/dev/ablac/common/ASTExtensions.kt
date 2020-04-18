package dev.ablac.common

import dev.ablac.language.nodes.File
import dev.ablac.language.nodes.FunctionDeclaration
import dev.ablac.language.nodes.Node
import dev.ablac.utils.BackingField

var File.symbolTable: SymbolTable? by BackingField.nullable()
var FunctionDeclaration.symbolTable: SymbolTable? by BackingField.nullable()
var Node.symbol: Symbol<*>? by BackingField.nullable()
