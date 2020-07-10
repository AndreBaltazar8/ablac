package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position
import dev.abla.utils.deepCopy

open class FunctionDeclaration(
    var name: String,
    var parameters: MutableList<AssignableParameter>,
    var block: Block?,
    var returnType: Type?,
    var modifiers: MutableList<Modifier>,
    var annotations: MutableList<Annotation>,
    var receiver: Type?,
    var genericTypes: MutableList<TypeDefParam>,
    override val position: Position
) : Statement {
    val isExtern get() = modifiers.any { it is Extern }
    val isAbstract get() = modifiers.any { it is Abstract }
    val isCompile get() = modifiers.any { it is ModCompile }

    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    override fun deepCopy(): FunctionDeclaration = FunctionDeclaration(
        name,
        parameters.deepCopy(),
        block?.deepCopy(),
        returnType?.deepCopy(),
        modifiers.deepCopy(),
        annotations.deepCopy(),
        receiver?.deepCopy(),
        genericTypes.deepCopy(),
        position.copy()
    )
}