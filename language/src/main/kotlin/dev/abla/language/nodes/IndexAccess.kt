package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

data class IndexAccess(
    var expression: Expression,
    var index: Expression,
    override val position: Position
) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    override fun deepCopy(): IndexAccess = IndexAccess(
        expression.deepCopy(),
        index.deepCopy(),
        position.copy()
    )
}