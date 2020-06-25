package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

data class FunctionLiteral(
    var block: Block,
    var parameters: MutableList<InferrableParameter>,
    override val position: Position
) : Literal {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}