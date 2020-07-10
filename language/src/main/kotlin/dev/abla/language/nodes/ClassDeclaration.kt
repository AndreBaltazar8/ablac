package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position
import dev.abla.utils.DeepCopy
import dev.abla.utils.deepCopy

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
    val isCompile get() = modifiers.any { it is ModCompile }

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    override fun deepCopy(): ClassDeclaration = ClassDeclaration(
        name,
        modifiers.deepCopy(),
        annotations.deepCopy(),
        constructor?.deepCopy(),
        declarations.deepCopy(),
        classType,
        isInterface,
        position.copy()
    )
}

object ClassType {
    const val Class = "class"
    const val Interface = "interface"
}

class ClassConstructor(val modifiers: MutableList<Modifier>, val parameters: MutableList<Node>, val position: Position) : DeepCopy<ClassConstructor> {
    override fun deepCopy(): ClassConstructor = ClassConstructor(
        modifiers.deepCopy(),
        parameters.deepCopy(),
        position.copy()
    )
}