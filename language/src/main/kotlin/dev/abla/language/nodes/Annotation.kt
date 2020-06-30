package dev.abla.language.nodes

import dev.abla.language.Identifier
import dev.abla.language.Position
import dev.abla.utils.DeepCopy
import dev.abla.utils.deepCopy

data class Annotation(
    var name: Identifier,
    var arguments: MutableList<Argument>,
    val position: Position
) : DeepCopy<Annotation> {
    override fun deepCopy(): Annotation = Annotation(
        name,
        arguments.deepCopy(),
        position.copy()
    )
}