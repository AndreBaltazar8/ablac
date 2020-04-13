package dev.ablac.language.nodes

import dev.ablac.language.ASTVisitor
import dev.ablac.language.Identifier
import dev.ablac.language.Position

class IdentifierExpression(val identifier: Identifier, override val position: Position) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}