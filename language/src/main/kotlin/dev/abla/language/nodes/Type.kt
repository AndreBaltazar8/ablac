package dev.abla.language.nodes

import dev.abla.language.Position
import dev.abla.utils.DeepCopy

interface Type : DeepCopy<Type> {
    val position: Position
    fun toHuman(): String
}

fun Type?.isNullOrVoid() = this == null || this == UserType.Void