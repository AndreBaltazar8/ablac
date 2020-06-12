package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

class Assignment(
    var lhs: Expression,
    var rhs: Expression,
    override val position: Position
) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}