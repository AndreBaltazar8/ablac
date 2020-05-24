package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

class WhenExpression(
    val condition: Expression?,
    val cases: MutableList<Case>,
    override val position: Position
) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    open class Case(open val body: Block)
    data class ExpressionCase(val expressions: MutableList<Expression>, override val body: Block) : Case(body)
    data class ElseCase(override val body: Block) : Case(body)

}