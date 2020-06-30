package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position
import dev.abla.utils.DeepCopy
import dev.abla.utils.deepCopy

class WhenExpression(
    var condition: Expression?,
    var cases: MutableList<Case>,
    override val position: Position
) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    override fun deepCopy(): WhenExpression = WhenExpression(
        condition?.deepCopy(),
        cases.deepCopy(),
        position.copy()
    )

    abstract class Case(open var body: Block) : DeepCopy<Case>

    data class ExpressionCase(var expressions: MutableList<Expression>, override var body: Block) : Case(body) {
        override fun deepCopy(): ExpressionCase = ExpressionCase(
            expressions.deepCopy(),
            body.deepCopy()
        )
    }

    data class ElseCase(override var body: Block) : Case(body) {
        override fun deepCopy(): ElseCase = ElseCase(
            body.deepCopy()
        )
    }
}