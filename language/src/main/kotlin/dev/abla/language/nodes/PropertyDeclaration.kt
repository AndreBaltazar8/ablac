package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Identifier
import dev.abla.language.Position

class PropertyDeclaration(
    val isFinal: Boolean,
    val name: Identifier,
    var type: Type?,
    val value: Expression?,
    override val position: Position
) : Statement {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}
