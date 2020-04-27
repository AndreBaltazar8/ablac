package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position

interface Node {
    val position: Position
    suspend fun accept(visitor: ASTVisitor)
}