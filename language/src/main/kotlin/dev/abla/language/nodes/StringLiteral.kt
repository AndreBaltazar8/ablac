package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

data class StringLiteral(val stringParts: Array<StringPart>, override val position: Position) : Literal {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as StringLiteral

        if (!stringParts.contentEquals(other.stringParts)) return false

        return true
    }

    override fun hashCode(): Int {
        return stringParts.contentHashCode()
    }

    open class StringPart
    data class StringConst(val string: String, val position: Position) : StringPart()
    data class StringExpression(val expression: Expression, val position: Position) : StringPart()
}