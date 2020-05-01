package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

open class FunctionDeclaration(
    val name: String,
    val parameters: Array<Parameter>,
    val block: Block?,
    val returnType: Type?,
    val modifiers: Array<Modifier>,
    override val position: Position
) : Declaration {
    val isExtern get() = modifiers.any { it is Extern }

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}