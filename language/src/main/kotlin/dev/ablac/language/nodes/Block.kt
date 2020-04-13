package dev.ablac.language.nodes

import dev.ablac.language.ASTVisitor
import dev.ablac.language.Position

class Block(val statements: Array<Statement>, override val position: Position) : Node {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}