package dev.ablac.language.nodes

import dev.ablac.language.ASTVisitor
import dev.ablac.language.Position

data class FunctionCall(
    val primaryExpression: PrimaryExpression,
    val arguments: Array<Argument>,
    override val position: Position
) : PrimaryExpression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}