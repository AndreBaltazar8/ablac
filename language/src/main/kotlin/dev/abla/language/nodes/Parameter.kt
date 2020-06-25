package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Identifier
import dev.abla.language.Position
import dev.abla.language.positionZero

data class Parameter(var name: Identifier, var type: Type, override val position: Position = positionZero) : Node {
    override suspend fun accept(visitor: ASTVisitor) {
        throw Exception("Process this in body of declaration")
    }
}

data class InferrableParameter(var name: Identifier, var type: Type?, override val position: Position = positionZero) : Node {
    override suspend fun accept(visitor: ASTVisitor) {
        throw Exception("Process this in body of declaration")
    }
}
