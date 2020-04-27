package dev.abla.common

import dev.abla.language.nodes.File
import dev.abla.language.nodes.FunctionDeclaration
import dev.abla.language.nodes.Node
import dev.abla.utils.BackingField

var File.symbolTable: SymbolTable? by BackingField.nullable()
var FunctionDeclaration.symbolTable: SymbolTable? by BackingField.nullable()
var Node.symbol: Symbol<*>? by BackingField.nullable()
