package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

class WhileStatement(
    val condition: Expression,
    val block: Block,
    override val position: Position
) : Statement {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}
