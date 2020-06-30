package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

data class Integer(var number: String, override val position: Position) : Literal {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    override fun deepCopy(): Integer = Integer(
        number,
        position.copy()
    )
}