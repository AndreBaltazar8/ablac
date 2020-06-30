package dev.abla.language.nodes

import dev.abla.language.Position

data class NullableType(val type: Type, override val position: Position) : Type {
    override fun toHuman(): String = "\"${type.toHuman()}\"?"

    override fun deepCopy(): NullableType = NullableType(
        type.deepCopy(),
        position.copy()
    )
}