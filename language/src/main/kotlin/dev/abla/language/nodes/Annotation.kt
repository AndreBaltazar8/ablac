package dev.abla.language.nodes

import dev.abla.language.Identifier
import dev.abla.language.Position

data class Annotation(
    val name: Identifier,
    val arguments: MutableList<Argument>,
    val position: Position
)