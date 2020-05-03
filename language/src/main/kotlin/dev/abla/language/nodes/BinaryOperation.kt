package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

data class BinaryOperation(
    val operator: BinaryOperator,
    val lhs: Expression,
    val rhs: Expression,
    override val position: Position
) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}

enum class BinaryOperator {
    Plus, Minus, Mul, Div,
    Equals, NotEquals,
    GreaterThan, LesserThan,
    GreaterThanEqual, LesserThanEqual
}