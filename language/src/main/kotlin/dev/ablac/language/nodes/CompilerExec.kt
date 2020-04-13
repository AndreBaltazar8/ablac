package dev.ablac.language.nodes

import dev.ablac.language.ASTVisitor
import dev.ablac.language.Position

class CompilerExec(val expression: Expression, override val position: Position) : Expression {
    override suspend fun accept(visitor: ASTVisitor) {
        visitor.visit(this);
    }
}