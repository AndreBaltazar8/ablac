package dev.ablac.language.nodes

import dev.ablac.language.ASTVisitor
import dev.ablac.language.Position

data class FunctionDeclaration(val name: String, val block: Block?, override val position: Position) : Declaration {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}