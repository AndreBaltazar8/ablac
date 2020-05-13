package dev.abla.language.nodes

import dev.abla.language.Identifier
import dev.abla.language.Position
import dev.abla.language.positionZero

data class UserType(
    val identifier: Identifier,
    val types: Array<Type> = arrayOf(),
    val parent: Type? = null,
    override val position: Position = positionZero
) : Type {

    val isGeneric = types.isNotEmpty()

    override fun toHuman(): String {
        return (if (parent != null) parent.toHuman() + "." else "") +
                identifier + if (isGeneric) "<${types.joinToString { it.toHuman() }}>" else ""
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as UserType

        if (identifier != other.identifier) return false
        if (!types.contentEquals(other.types)) return false
        if (parent != other.parent) return false

        return true
    }

    override fun hashCode(): Int {
        var result = identifier.hashCode()
        result = 31 * result + types.contentHashCode()
        result = 31 * result + (parent?.hashCode() ?: 0)
        return result
    }

    companion object {
        val Void = UserType("void")
        val Int = UserType("int")
        val Bool = UserType("bool")
        val String = UserType("string")
        val Any = UserType("any")
    }
}