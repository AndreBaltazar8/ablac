package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Identifier
import dev.abla.language.Position
import dev.abla.language.positionZero

open class Parameter(var name: Identifier, var type: Type, override val position: Position = positionZero) : Node {
    override suspend fun accept(visitor: ASTVisitor) {
        throw Exception("Process this in body of declaration")
    }

    override fun deepCopy(): Parameter = Parameter(
        name,
        type.deepCopy(),
        position.copy()
    )
}

class AssignableParameter(
    name: Identifier,
    type: Type,
    var expression: Expression? = null,
    position: Position = positionZero
) : Parameter(name, type, position) {
    override fun deepCopy(): AssignableParameter = AssignableParameter(
        name,
        type.deepCopy(),
        expression?.deepCopy(),
        position.copy()
    )
}

data class InferrableParameter(var name: Identifier, var type: Type?, override val position: Position = positionZero) : Node {
    override suspend fun accept(visitor: ASTVisitor) {
        throw Exception("Process this in body of declaration")
    }

    override fun deepCopy(): InferrableParameter = InferrableParameter(
        name,
        type?.deepCopy(),
        position.copy()
    )
}
