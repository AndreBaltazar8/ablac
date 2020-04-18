package dev.ablac.language.nodes

import dev.ablac.language.ASTVisitor
import dev.ablac.language.Position

open class FunctionDeclaration(
    val name: String,
    val parameters: Array<Parameter>,
    val block: Block?,
    val modifiers: Array<Modifier>,
    override val position: Position
) : Declaration {
    val isExtern get() = modifiers.any { it is Extern }

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}