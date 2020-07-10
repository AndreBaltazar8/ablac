package dev.abla.language.nodes

import dev.abla.language.Position
import dev.abla.utils.DeepCopy

interface Modifier : DeepCopy<Modifier>

data class Extern(var libName: StringLiteral?, val position: Position) : Modifier {
    override fun deepCopy(): Extern = Extern(
        libName?.deepCopy(),
        position.copy()
    )
}

data class Abstract(val position: Position) : Modifier {
    override fun deepCopy(): Abstract = Abstract(
        position.copy()
    )
}

data class ModCompile(val position: Position) : Modifier {
    override fun deepCopy(): ModCompile = ModCompile(
        position.copy()
    )
}