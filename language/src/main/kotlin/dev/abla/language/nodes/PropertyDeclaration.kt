package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Identifier
import dev.abla.language.Position
import dev.abla.utils.deepCopy

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

    override fun deepCopy(): PropertyDeclaration = PropertyDeclaration(
        isFinal,
        name,
        type?.deepCopy(),
        value?.deepCopy(),
        modifiers.deepCopy(),
        position.copy()
    )
}
