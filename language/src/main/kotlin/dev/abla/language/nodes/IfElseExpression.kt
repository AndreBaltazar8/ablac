package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

class IfElseExpression(
    var condition: Expression,
    var ifBody: Block,
    var elseBody: Block?,
    override val position: Position
) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    override fun deepCopy(): IfElseExpression = IfElseExpression(
        condition.deepCopy(),
        ifBody.deepCopy(),
        elseBody?.deepCopy(),
        position.copy()
    )
}