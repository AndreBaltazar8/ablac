package dev.abla.language

import dev.abla.language.nodes.*

class PrintVisitor : ASTVisitor() {
    override suspend fun visit(type: Type) {
    }

    override suspend fun visit(typeDef: TypeDef) {
    }

    override suspend fun visit(file: File) {
        println("// ${file.fileName}")
        super.visit(file)
    }

    override suspend fun visit(functionDeclaration: FunctionDeclaration) {
    }

    override suspend fun visit(compilerExec: CompilerExec) {
    }

    override suspend fun visit(identifierExpression: IdentifierExpression) {
    }
}