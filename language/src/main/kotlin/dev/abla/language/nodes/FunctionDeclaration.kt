package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

open class FunctionDeclaration(
    var name: String,
    val parameters: Array<Parameter>,
    var block: Block?,
    val returnType: Type?,
    val modifiers: Array<Modifier>,
    override val position: Position
) : Statement {
    val isExtern get() = modifiers.any { it is Extern }
    val isCompiler get() = modifiers.any { it is ModCompiler }

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}