package dev.ablac.language.nodes

import dev.ablac.language.ASTVisitor
import dev.ablac.language.Position

interface Node {
    val position: Position
    suspend fun accept(visitor: ASTVisitor)
}