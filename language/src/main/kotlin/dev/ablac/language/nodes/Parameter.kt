package dev.ablac.language.nodes

import dev.ablac.language.ASTVisitor
import dev.ablac.language.Identifier
import dev.ablac.language.Position
import dev.ablac.language.positionZero

data class Parameter(val name: Identifier, val type: Type, override val position: Position = positionZero) : Node {
    override suspend fun accept(visitor: ASTVisitor) {
        throw Exception("Process this in body of declaration")
    }
}
