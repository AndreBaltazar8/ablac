package dev.ablac.frontend

import dev.ablac.common.Symbol
import dev.ablac.common.SymbolTable
import dev.ablac.common.symbolTable
import dev.ablac.language.ASTVisitor
import dev.ablac.language.nodes.File
import dev.ablac.language.nodes.FunctionDeclaration
import java.util.*

class TypeGather(val global: SymbolTable) : ASTVisitor() {
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

        // TODO: function args

        functionDeclaration.block?.accept(this)
        tables.pop()
    }
}