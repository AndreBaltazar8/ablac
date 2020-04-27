package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Identifier
import dev.abla.language.Position

class IdentifierExpression(
    val identifier: Identifier,
    override val position: Position
) : PrimaryExpression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}