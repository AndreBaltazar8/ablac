package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position
import dev.abla.utils.DeepCopy
import dev.abla.utils.deepCopy

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

    override fun deepCopy(): StringLiteral = StringLiteral(
        stringParts.deepCopy(),
        position.copy()
    )

    interface StringPart : DeepCopy<StringPart>
    data class StringConst(val string: String, val position: Position) : StringPart {
        override fun deepCopy(): StringConst = StringConst(
            string,
            position.copy()
        )
    }

    data class StringExpression(val expression: Expression, val position: Position) : StringPart {
        override fun deepCopy(): StringExpression = StringExpression(
            expression.deepCopy(),
            position.copy()
        )
    }
}