package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

data class NullLiteral(override val position: Position) : Literal {
    override fun deepCopy(): NullLiteral = NullLiteral(
        position.copy()
    )

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}