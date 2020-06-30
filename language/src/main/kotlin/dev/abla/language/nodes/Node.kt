package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position
import dev.abla.utils.DeepCopy

interface Node : DeepCopy<Node> {
    val position: Position
    suspend fun accept(visitor: ASTVisitor)
}