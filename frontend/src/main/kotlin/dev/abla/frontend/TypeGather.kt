package dev.abla.frontend

import dev.abla.common.Symbol
import dev.abla.common.SymbolTable
import dev.abla.common.symbolTable
import dev.abla.language.ASTVisitor
import dev.abla.language.nodes.File
import dev.abla.language.nodes.FunctionDeclaration
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

        val table = SymbolTable(tables.peek())
        tables.push(table)
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
        tables.pop()
    }
}