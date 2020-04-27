package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

class Block(val statements: Array<Statement>, override val position: Position) : Node {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}