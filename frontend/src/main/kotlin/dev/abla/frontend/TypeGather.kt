package dev.abla.frontend

import dev.abla.common.*
import dev.abla.language.ASTVisitor
import dev.abla.language.nodes.*
import java.util.*

class TypeGather(private val global: SymbolTable) : ASTVisitor() {
    private val tables = Stack<SymbolTable>().apply {
        push(global)
    }

    override suspend fun visit(file: File) {
        file.symbolTable = tables.peek()
        super.visit(file)
    }

    override suspend fun visit(functionDeclaration: FunctionDeclaration) {
        val function = Symbol.Function(functionDeclaration.name, functionDeclaration)
        tables.peek().symbols.add(function)

        createTableInParent { table ->
            functionDeclaration.symbolTable = table

            val extern = functionDeclaration.isExtern
            if (extern && functionDeclaration.block != null)
                throw Exception("Extern function cannot have a body")
            if (!extern && functionDeclaration.block == null)
                throw Exception("Function must have a body or be declared extern or abstract")

            functionDeclaration.parameters.forEach {
                table.symbols.add(Symbol.Variable(it.name, it))
            }

            functionDeclaration.block?.accept(this)
        }
    }

    override suspend fun visit(ifElseExpression: IfElseExpression) {
        ifElseExpression.condition.accept(this)

        val ifBody = ifElseExpression.ifBody
        if (ifBody != null) {
            createTableInParent { ifTable ->
                ifElseExpression.ifSymbolTable = ifTable
                ifBody.accept(this)
            }
        }

        val elseBody = ifElseExpression.elseBody
        if (elseBody != null) {
            createTableInParent { elseTable ->
                ifElseExpression.elseSymbolTable = elseTable
                elseBody.accept(this)
            }
        }
    }

    override suspend fun visit(propertyDeclaration: PropertyDeclaration) {
        val variable = Symbol.Variable(propertyDeclaration.name, propertyDeclaration)
        tables.peek().symbols.add(variable)

        super.visit(propertyDeclaration)
    }

    override suspend fun visit(whileStatement: WhileStatement) {
        createTableInParent { table ->
            whileStatement.symbolTable = table
            super.visit(whileStatement)
        }
    }

    override suspend fun visit(assignment: Assignment) {
        assignment.lhs.returnForAssignment = true
        super.visit(assignment)
    }

    private inline fun createTableInParent(action: (table: SymbolTable) -> Unit) {
        val table = SymbolTable(tables.peek())
        tables.push(table)
        action(table)
        tables.pop()
    }
}