package dev.abla.language.nodes

import dev.abla.language.Identifier
import dev.abla.language.Position
import dev.abla.utils.DeepCopy
import dev.abla.utils.deepCopy

data class TypeDef(
    val identifier: Identifier,
    val types: Array<TypeDefParam>,
    val position: Position
) : DeepCopy<TypeDef> {
    val isGeneric get() = types.isNotEmpty()

    fun toHuman(): String {
        return identifier + if (isGeneric) "<${types.joinToString { it.toHuman() }}>" else ""
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as TypeDef

        if (identifier != other.identifier) return false
        if (!types.contentEquals(other.types)) return false

        return true
    }

    override fun hashCode(): Int {
        var result = identifier.hashCode()
        result = 31 * result + types.contentHashCode()
        return result
    }

    override fun deepCopy(): TypeDef = TypeDef(
        identifier,
        types.deepCopy(),
        position.copy()
    )
}

data class TypeDefParam(val type: TypeDef, val constraint: Type? = null) : DeepCopy<TypeDefParam> {
    val isConstrained get() = constraint != null

    fun toHuman(): String {
        return type.toHuman() + if (constraint != null) " : ${constraint.toHuman()}" else ""
    }

    override fun deepCopy(): TypeDefParam = TypeDefParam(
        type.deepCopy(),
        constraint?.deepCopy()
    )
}
