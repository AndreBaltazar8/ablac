package dev.abla.language.nodes

import dev.abla.language.Identifier
import dev.abla.language.Position

data class Annotation(
    var name: Identifier,
    var arguments: MutableList<Argument>,
    val position: Position
)