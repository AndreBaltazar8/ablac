package dev.ablac.language.nodes

import dev.ablac.language.ASTVisitor
import dev.ablac.language.Identifier
import dev.ablac.language.Position
import dev.ablac.language.positionZero

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