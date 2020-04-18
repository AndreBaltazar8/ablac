package dev.ablac.frontend

import dev.ablac.common.SymbolTable
import dev.ablac.language.nodes.Literal

class ExecutionScope(val parent: ExecutionScope?, val symbolTable: SymbolTable) {
    private val values = mutableMapOf<String, Literal>()

    operator fun get(identifier: String) : Literal? = values[identifier] ?: parent?.get(identifier)
    operator fun set(identifier: String, literal: Literal) {
        values[identifier] = literal
    }
}