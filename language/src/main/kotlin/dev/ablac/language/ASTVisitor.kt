package dev.ablac.language

import dev.ablac.language.nodes.*

abstract class ASTVisitor {
    open suspend fun visit(type: Type) {
    }

    open suspend fun visit(typeDef: TypeDef) {
    }

    open suspend fun visit(file: File) {
        file.declarations.forEach {
            it.accept(this)
        }
    }

    open suspend fun visit(functionDeclaration: FunctionDeclaration) {
        functionDeclaration.block?.accept(this)
    }

    open suspend fun visit(block: Block) {
        block.statements.forEach {
            it.accept(this)
        }
    }

    open suspend fun visit(compilerExec: CompilerExec) {
        compilerExec.expression.accept(this)
    }

    open suspend fun visit(identifierExpression: IdentifierExpression) {
    }

    open suspend fun visit(integer: Integer) {
    }

    open suspend fun visit(stringLiteral: StringLiteral) {
    }

    open suspend fun visit(functionCall: FunctionCall) {
    }
}