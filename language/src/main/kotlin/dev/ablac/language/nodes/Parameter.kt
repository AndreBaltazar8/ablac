package dev.ablac.language.nodes

import dev.ablac.language.ASTVisitor
import dev.ablac.language.Identifier
import dev.ablac.language.Position

data class Parameter(val name: Identifier, val type: Type, override val position: Position) : Node {
    override suspend fun accept(visitor: ASTVisitor) {
        throw Exception("Process this in body of declaration")
    }
}
