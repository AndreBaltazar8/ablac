package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

data class FunctionCall(
    val primaryExpression: PrimaryExpression,
    val arguments: Array<Argument>,
    override val position: Position
) : PrimaryExpression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}