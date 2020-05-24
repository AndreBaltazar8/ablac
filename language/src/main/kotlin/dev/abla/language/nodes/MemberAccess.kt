package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

data class MemberAccess(
    val expression: Expression,
    val name: String,
    override val position: Position
) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}