package dev.abla.language.nodes

import dev.abla.language.Position

data class PointerType(val type: Type, override val position: Position) : Type {
    override fun toHuman(): String = "\"${type.toHuman()}\"*"
}