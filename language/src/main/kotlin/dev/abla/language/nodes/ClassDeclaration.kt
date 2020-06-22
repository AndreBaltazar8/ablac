package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

open class ClassDeclaration(
    var name: String,
    var modifiers: MutableList<Modifier>,
    var annotations: MutableList<Annotation>,
    var constructor: ClassConstructor?,
    var declarations: MutableList<Declaration>,
    var classType: String,
    var isInterface: Boolean,
    override val position: Position
) : Declaration {
    val isCompiler get() = modifiers.any { it is ModCompiler }

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }
}

object ClassType {
    const val Class = "class"
    const val Interface = "interface"
}

class ClassConstructor(val modifiers: MutableList<Modifier>, val parameters: MutableList<Node>, val position: Position)