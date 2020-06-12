package dev.abla.language.nodes

import dev.abla.language.Position

interface Modifier
data class Extern(var libName: StringLiteral?, val position: Position) : Modifier
data class Abstract(val position: Position) : Modifier
data class ModCompiler(val position: Position) : Modifier