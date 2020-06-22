package dev.abla.frontend

import dev.abla.common.*
import dev.abla.language.ASTVisitor
import dev.abla.language.nodes.*
import java.lang.IllegalStateException
import java.util.*

class TypeGather(private val global: SymbolTable) : ASTVisitor() {
    private var currentScope = Scope.Global
    private val classScopes = Stack<Symbol.Class>()

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

        var isInInterfaceClass = false
        val receiverType = functionDeclaration.receiver
        if (receiverType != null) {
            if (receiverType !is UserType) // TODO: support other types. This will still crash for builtin UserTypes
                throw Exception("Not supported")
            val symbol = tables.peek().find(receiverType.identifier)
            if (symbol !is Symbol.Class)
                throw Exception("Expecting class symbol")
            function.receiver = symbol
        } else if (currentScope == Scope.Class) {
            val classSymbol = classScopes.peek()
            isInInterfaceClass = classSymbol.node.isInterface
            classSymbol.methods.add(function)
            function.receiver = classSymbol
        }

        createTableInParent { table ->
            functionDeclaration.symbolTable = table
            if (function.receiver != null) {
                val parameter = Parameter("this", function.receiver!!.node.toType())
                table.symbols.add(Symbol.Variable("this", parameter))
                functionDeclaration.receiverParameter = parameter
            }

            val extern = functionDeclaration.isExtern
            if (extern && functionDeclaration.block != null)
                throw Exception("Extern function cannot have a body")
            if (!extern && !(functionDeclaration.isAbstract || isInInterfaceClass) && functionDeclaration.block == null)
                throw Exception("Function must have a body or be declared extern or abstract")

            functionDeclaration.parameters.forEach {
                table.symbols.add(Symbol.Variable(it.name, it))
            }

            if (functionDeclaration.isCompiler) {
                table.symbols.add(
                    Symbol.Variable(
                        "compilerContext",
                        Parameter("compilerContext", UserType("CompilerContext"))
                    )
                )
            }

            createTableInParent { blockTable ->
                functionDeclaration.block?.symbolTable = blockTable

                withScope(Scope.Function) {
                    functionDeclaration.block?.accept(this)
                }
            }
        }
    }

    override suspend fun visit(functionLiteral: FunctionLiteral) {
        createTableInParent { table ->
            functionLiteral.block.symbolTable = table
            withScope(Scope.Function) {
                super.visit(functionLiteral)
            }
        }
    }

    override suspend fun visit(ifElseExpression: IfElseExpression) {
        ifElseExpression.condition.accept(this)

        val ifBody = ifElseExpression.ifBody
        createTableInParent { ifTable ->
            ifElseExpression.ifBody.symbolTable = ifTable
            ifBody.accept(this)
        }

        val elseBody = ifElseExpression.elseBody
        if (elseBody != null) {
            createTableInParent { elseTable ->
                elseBody.symbolTable = elseTable
                elseBody.accept(this)
            }
        }
    }

    override suspend fun visit(classDeclaration: ClassDeclaration) {
        if (classDeclaration.isInterface) {
            if (classDeclaration.constructor != null)
                throw Exception("Interface classes cannot have constructor")
        }

        val classSymbol = Symbol.Class(classDeclaration.name, classDeclaration)
        tables.peek().symbols.add(classSymbol)
        classScopes.push(classSymbol)

        createTableInParent {
            classDeclaration.symbolTable = it
            withScope(Scope.Class) {
                super.visit(classDeclaration)
            }
        }

        classScopes.pop()
    }

    override suspend fun visit(propertyDeclaration: PropertyDeclaration) {
        propertyDeclaration.scope = currentScope
        if (currentScope == Scope.Global && propertyDeclaration.value != null && !propertyDeclaration.value.isLiteralOrCompileTime()) {
            throw IllegalStateException("Must be a constant at runtime. Use compile time execution or a literal")
        }
        propertyDeclaration.symbolTable = tables.peek()
        val variable = Symbol.Variable(propertyDeclaration.name, propertyDeclaration)
        tables.peek().symbols.add(variable)
        if (currentScope == Scope.Class) {
            val classSymbol = classScopes.peek()
            variable.classSymbol = classSymbol
            classSymbol.fields.add(variable)
        }

        super.visit(propertyDeclaration)
    }

    override suspend fun visit(whileStatement: WhileStatement) {
        createTableInParent { table ->
            whileStatement.block.symbolTable = table
            super.visit(whileStatement)
        }
    }

    override suspend fun visit(assignment: Assignment) {
        assignment.lhs.returnForAssignment = true
        super.visit(assignment)
    }

    override suspend fun visit(whenExpression: WhenExpression) {
        whenExpression.condition?.accept(this)
        whenExpression.cases.forEach {
            if (it is WhenExpression.ExpressionCase)
                it.expressions.forEach { expression -> expression.accept(this) }
            createTableInParent { table ->
                it.body.symbolTable = table
                it.body.accept(this)
            }
        }
    }

    private inline fun createTableInParent(action: (table: SymbolTable) -> Unit) {
        val table = SymbolTable(tables.peek())
        tables.push(table)
        action(table)
        tables.pop()
    }

    private inline fun withScope(scope: Scope, action: () -> Unit) {
        val prevScope = currentScope
        currentScope = scope
        action()
        currentScope = prevScope
    }
}
