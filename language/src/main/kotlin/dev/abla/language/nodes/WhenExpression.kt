package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

class WhenExpression(
    var condition: Expression?,
    var cases: MutableList<Case>,
    override val position: Position
) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    open class Case(open var body: Block)
    data class ExpressionCase(var expressions: MutableList<Expression>, override var body: Block) : Case(body)
    data class ElseCase(override var body: Block) : Case(body)

}