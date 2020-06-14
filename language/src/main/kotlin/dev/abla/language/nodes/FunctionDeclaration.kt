package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

open class FunctionDeclaration(
    var name: String,
    var parameters: MutableList<Parameter>,
    var block: Block?,
    var returnType: Type?,
    var modifiers: MutableList<Modifier>,
    var annotations: MutableList<Annotation>,
    var receiver: Type?,
    override val position: Position
) : Statement {
    val isExtern get() = modifiers.any { it is Extern }
    val isAbstract get() = modifiers.any { it is Abstract }
    val isCompiler get() = modifiers.any { it is ModCompiler }

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}