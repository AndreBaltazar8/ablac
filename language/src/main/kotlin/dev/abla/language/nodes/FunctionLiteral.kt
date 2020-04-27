package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

data class FunctionLiteral(
    val block: Block,
    override val position: Position
) : Literal {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}