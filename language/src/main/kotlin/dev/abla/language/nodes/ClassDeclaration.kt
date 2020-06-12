package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

open class ClassDeclaration(
    var name: String,
    var modifiers: MutableList<Modifier>,
    var constructor: ClassConstructor?,
    var declarations: MutableList<Declaration>,
    override val position: Position
) : Declaration {
    val isCompiler get() = modifiers.any { it is ModCompiler }

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}

class ClassConstructor(val modifiers: MutableList<Modifier>, val parameters: MutableList<Node>, val position: Position)