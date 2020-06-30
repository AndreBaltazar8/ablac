package dev.abla.language.nodes

import dev.abla.language.Identifier
import dev.abla.language.Position
import dev.abla.utils.DeepCopy

data class Argument(var name: Identifier?, var value: Expression, val position: Position) : DeepCopy<Argument> {
    override fun deepCopy(): Argument = Argument(
        name,
        value.deepCopy(),
        position.copy()
    )
}