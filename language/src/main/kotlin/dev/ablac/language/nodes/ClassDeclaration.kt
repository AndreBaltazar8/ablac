package dev.ablac.language.nodes

import dev.ablac.language.ASTVisitor
import dev.ablac.language.Position

open class ClassDeclaration(
    val name: String,
    val modifiers: Array<Modifier>,
    val declarations: Array<Declaration>,
    override val position: Position
) : Declaration {

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}