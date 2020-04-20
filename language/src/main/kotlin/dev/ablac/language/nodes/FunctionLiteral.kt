package dev.ablac.language.nodes

import dev.ablac.language.ASTVisitor
import dev.ablac.language.Position

data class FunctionLiteral(
    val block: Block,
    override val position: Position
) : Literal {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}