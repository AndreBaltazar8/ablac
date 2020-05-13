package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

data class MemberAccess(
    val primaryExpression: PrimaryExpression,
    val name: String,
    override val position: Position
) : PrimaryExpression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}