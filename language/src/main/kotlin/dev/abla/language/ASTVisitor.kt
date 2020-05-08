package dev.abla.language

import dev.abla.language.nodes.*

abstract class ASTVisitor {
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
        functionCall.primaryExpression.accept(this)
        functionCall.arguments.forEach { it.value.accept(this) }
    }

    open suspend fun visit(functionLiteral: FunctionLiteral) {
        functionLiteral.block.accept(this)
    }

    open suspend fun visit(classDeclaration: ClassDeclaration) {
        classDeclaration.declarations.forEach { it.accept(this) }
    }

    open suspend fun visit(binaryOperation: BinaryOperation) {
        binaryOperation.lhs.accept(this)
        binaryOperation.rhs.accept(this)
    }

    open suspend fun visit(ifElseExpression: IfElseExpression) {
        ifElseExpression.condition.accept(this)
        ifElseExpression.ifBody?.accept(this)
        ifElseExpression.elseBody?.accept(this)
    }

    open suspend fun visit(propertyDeclaration: PropertyDeclaration) {
        propertyDeclaration.value?.accept(this)
    }

    open suspend fun visit(assignment: Assignment) {
        assignment.lhs.accept(this)
        assignment.rhs.accept(this)
    }

    open suspend fun visit(whileStatement: WhileStatement) {
        whileStatement.condition.accept(this)
        whileStatement.block?.accept(this)
    }
}