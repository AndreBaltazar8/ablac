package dev.abla.frontend

import dev.abla.common.SymbolTable
import dev.abla.language.nodes.Literal
import java.lang.IllegalStateException

class ExecutionScope(val parent: ExecutionScope?, val symbolTable: SymbolTable) {
    private val values = mutableMapOf<String, Literal>()

    operator fun get(identifier: String) : Literal? = values[identifier] ?: parent?.get(identifier)
    operator fun set(identifier: String, literal: Literal) {
        values[identifier] = literal
    }

    fun modify(identifier: String, value: Literal) {
        if (values.containsKey(identifier))
            values[identifier] = value
        else if (parent == null)
            throw IllegalStateException("Can't find $identifier to modify.")
        else
            parent.modify(identifier, value)
    }
}