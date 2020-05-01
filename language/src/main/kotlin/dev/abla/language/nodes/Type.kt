package dev.abla.language.nodes

import dev.abla.language.Position

interface Type {
    val position: Position
    fun toHuman(): String
}

fun Type?.isNullOrVoid() = this == null || this == UserType.Void