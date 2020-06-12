package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

data class Block(var statements: MutableList<Statement>, override val position: Position) : Node {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}