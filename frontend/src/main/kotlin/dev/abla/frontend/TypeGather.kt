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
        if (currentScope == Scope.Class) {
            val classSymbol = classScopes.peek()
            classSymbol.methods.add(function)
            function.receiver = classSymbol
        }

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

            if (functionDeclaration.isCompiler) {
                table.symbols.add(
                    Symbol.Variable(
                        "compilerContext",
                        Parameter("compilerContext", UserType("CompilerContext"))
                    )
                )
            }

            withScope(Scope.Function) {
                functionDeclaration.block?.accept(this)
            }
        }
    }

    override suspend fun visit(functionLiteral: FunctionLiteral) {
        withScope(Scope.Function) {
            super.visit(functionLiteral)
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

    override suspend fun visit(classDeclaration: ClassDeclaration) {
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
        val variable = Symbol.Variable(propertyDeclaration.name, propertyDeclaration)
        tables.peek().symbols.add(variable)
        if (propertyDeclaration.type == null) {
            propertyDeclaration.type = UserType.Int // TODO: type inference
        }
        if (currentScope == Scope.Class) {
            val classSymbol = classScopes.peek()
            variable.classSymbol = classSymbol
            classSymbol.fields.add(variable)
        }

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

    private inline fun withScope(scope: Scope, action: () -> Unit) {
        val prevScope = currentScope
        currentScope = scope
        action()
        currentScope = prevScope
    }
}
