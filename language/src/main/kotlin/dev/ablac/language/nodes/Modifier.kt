package dev.ablac.language.nodes

import dev.ablac.language.Position

interface Modifier
data class Extern(val libName: StringLiteral?, val position: Position) : Modifier