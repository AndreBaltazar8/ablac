package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

class WhileStatement(
    var condition: Expression,
    var block: Block,
    val doWhile: Boolean,
    override val position: Position
) : Statement {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}
