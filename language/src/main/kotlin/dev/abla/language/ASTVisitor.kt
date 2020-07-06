package dev.abla.language

import dev.abla.language.nodes.*
import dev.abla.utils.statementOrder

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
        stringLiteral.stringParts.forEach { part ->
            if (part is StringLiteral.StringExpression)
                part.expression.accept(this)
        }
    }

    open suspend fun visit(functionCall: FunctionCall) {
        functionCall.expression.accept(this)
        functionCall.arguments.forEach { it.value.accept(this) }
    }

    open suspend fun visit(functionLiteral: FunctionLiteral) {
        functionLiteral.block.accept(this)
    }

    open suspend fun visit(classDeclaration: ClassDeclaration) {
        classDeclaration.constructor?.parameters?.forEach {
            when (it) {
                is PropertyDeclaration -> it.accept(this)
            }
        }
        classDeclaration.declarations.forEach { it.accept(this) }
    }

    open suspend fun visit(binaryOperation: BinaryOperation) {
        binaryOperation.lhs.accept(this)
        binaryOperation.rhs.accept(this)
    }

    open suspend fun visit(ifElseExpression: IfElseExpression) {
        ifElseExpression.condition.accept(this)
        ifElseExpression.ifBody.accept(this)
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
        statementOrder(
            whileStatement.doWhile,
            { whileStatement.condition.accept(this) },
            { whileStatement.block.accept(this) }
        )
    }

    open suspend fun visit(memberAccess: MemberAccess) {
        memberAccess.expression.accept(this)
    }

    open suspend fun visit(whenExpression: WhenExpression) {
        whenExpression.condition?.accept(this)
        whenExpression.cases.forEach {
            if (it is WhenExpression.ExpressionCase)
                it.expressions.forEach { expression -> expression.accept(this) }
            it.body.accept(this)
        }
    }

    open suspend fun visit(arrayLiteral: ArrayLiteral) {
        arrayLiteral.elements.forEach { it.accept(this) }
    }

    open suspend fun visit(indexAccess: IndexAccess) {
        indexAccess.index.accept(this)
        indexAccess.expression.accept(this)
    }

    open suspend fun visit(nullLiteral: NullLiteral) {
    }
}