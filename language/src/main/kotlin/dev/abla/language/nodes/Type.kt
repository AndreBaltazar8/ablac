package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Identifier
import dev.abla.language.Position
import dev.abla.language.positionZero

data class Type(
    val identifier: Identifier,
    val types: Array<Type> = arrayOf(),
    override val position: Position = positionZero
) : Node {
    val isGeneric = types.isNotEmpty()

    fun toHuman(): String {
        return identifier + if (isGeneric) "<${types.joinToString { it.toHuman() }}>" else ""
    }

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as Type

        if (identifier != other.identifier) return false
        if (!types.contentEquals(other.types)) return false

        return true
    }

    override fun hashCode(): Int {
        var result = identifier.hashCode()
        result = 31 * result + types.contentHashCode()
        return result
    }
}