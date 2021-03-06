package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position
import dev.abla.utils.deepCopy

data class FunctionCall(
    var expression: Expression,
    var arguments: MutableList<Argument>,
    val typeArgs: MutableList<Type>,
    override val position: Position
) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    override fun deepCopy(): FunctionCall = FunctionCall(
        expression.deepCopy(),
        arguments.deepCopy(),
        typeArgs.deepCopy(),
        position.copy()
    )
}