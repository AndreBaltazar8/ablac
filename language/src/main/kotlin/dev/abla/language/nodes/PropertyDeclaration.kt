package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Identifier
import dev.abla.language.Position

class PropertyDeclaration(
    var isFinal: Boolean,
    var name: Identifier,
    var type: Type?,
    var value: Expression?,
    var modifiers: MutableList<Modifier>,
    override val position: Position
) : Statement {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}
