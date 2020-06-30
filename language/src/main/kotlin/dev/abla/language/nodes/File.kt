package dev.abla.language.nodes

import dev.abla.language.ASTVisitor
import dev.abla.language.Position
import dev.abla.utils.deepCopy

data class File(var fileName: String, var declarations: MutableList<Declaration>, override val position: Position) : Node {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this)
    }

    override fun deepCopy(): File = File(
        fileName,
        declarations.deepCopy(),
        position.copy()
    )
}