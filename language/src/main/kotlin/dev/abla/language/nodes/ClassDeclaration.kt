package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

open class ClassDeclaration(
    val name: String,
    val modifiers: Array<Modifier>,
    val constructor: ClassConstructor?,
    val declarations: Array<Declaration>,
    override val position: Position
) : Declaration {
    val isCompiler get() = modifiers.any { it is ModCompiler }

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}

class ClassConstructor(val modifiers: Array<Modifier>, val parameters: Array<Node>, val position: Position)