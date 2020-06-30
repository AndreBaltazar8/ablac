package dev.abla.language.nodes

import dev.abla.language.Identifier
import dev.abla.language.Position
import dev.abla.language.positionZero
import dev.abla.utils.deepCopy

data class UserType(
    val identifier: Identifier,
    val types: Array<Type> = arrayOf(),
    val parent: Type? = null,
    override val position: Position = positionZero
) : Type {
    val isGeneric = types.isNotEmpty()
    val isBuiltIn: Boolean
        get() = builtInTypes.contains(identifier)

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

    override fun deepCopy(): UserType = UserType(
        identifier,
        types.deepCopy(),
        parent?.deepCopy(),
        position.copy()
    )

    companion object {
        val builtInTypes = mutableSetOf<String>()

        val Void = UserType("void").also { builtInTypes.add(it.identifier) }
        val Int = UserType("int").also { builtInTypes.add(it.identifier) }
        val Bool = UserType("bool").also { builtInTypes.add(it.identifier) }
        val String = UserType("string").also { builtInTypes.add(it.identifier) }
        val Any = UserType("any").also { builtInTypes.add(it.identifier) }
        val Array = UserType("array").also { builtInTypes.add(it.identifier) }
    }
}