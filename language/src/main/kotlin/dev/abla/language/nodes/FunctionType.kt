package dev.abla.language.nodes

import dev.abla.language.Position

data class FunctionType(
    val parameters: Array<Parameter>,
    val returnType: Type,
    val receiver: Type?,
    override val position: Position
) : Type {
    override fun toHuman(): String = "#func#"

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as FunctionType

        if (!parameters.contentEquals(other.parameters)) return false
        if (returnType != other.returnType) return false
        if (receiver != other.receiver) return false

        return true
    }

    override fun hashCode(): Int {
        var result = parameters.contentHashCode()
        result = 31 * result + returnType.hashCode()
        result = 31 * result + (receiver?.hashCode() ?: 0)
        return result
    }
}