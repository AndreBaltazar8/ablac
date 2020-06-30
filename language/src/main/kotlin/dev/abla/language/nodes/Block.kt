package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position
import dev.abla.utils.deepCopy

data class Block(var statements: MutableList<Statement>, override val position: Position) : Node {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    override fun deepCopy(): Block = Block(
        statements.deepCopy(),
        position.copy()
    )
}