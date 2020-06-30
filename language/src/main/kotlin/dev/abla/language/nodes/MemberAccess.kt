package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

data class MemberAccess(
    var expression: Expression,
    var name: String,
    override val position: Position
) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    override fun deepCopy(): MemberAccess = MemberAccess(
        expression.deepCopy(),
        name,
        position.copy()
    )
}