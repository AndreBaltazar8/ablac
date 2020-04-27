package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Identifier
import dev.abla.language.Position

data class TypeDef(val identifier: Identifier, val types: Array<TypeDefParam>, override val position: Position) : Node {
    val isGeneric get() = types.isNotEmpty()

    fun toHuman(): String {
        return identifier + if (isGeneric) "<${types.joinToString { it.toHuman() }}>" else ""
    }

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
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
}

data class TypeDefParam(val type: TypeDef, val constraint: Type? = null) {
    val isConstrained get() = constraint != null

    fun toHuman(): String {
        return type.toHuman() + if (constraint != null) " : ${constraint.toHuman()}" else ""
    }
}
