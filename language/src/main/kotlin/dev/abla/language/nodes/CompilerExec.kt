package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

class CompilerExec(
    var expression: Expression,
    override val position: Position
) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}