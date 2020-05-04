package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

class IfElseExpression(
    val condition: Expression,
    val ifBody: Block?,
    val elseBody: Block?,
    override val position: Position
) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}