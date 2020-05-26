package dev.abla.frontend

import dev.abla.common.SymbolTable
import dev.abla.language.nodes.Literal
import java.lang.IllegalStateException

open class ExecutionScope(val parent: ExecutionScope?, val symbolTable: SymbolTable) {
    private val values = mutableMapOf<String, ExecutionValue>()

    operator fun get(identifier: String) : ExecutionValue? =
        values[identifier] ?:
        symbolTable.getThis(identifier)?.let { ExecutionValue.ConstSymbol(it) } ?:
        parent?.get(identifier)

    operator fun set(identifier: String, value: ExecutionValue) {
        values[identifier] = value
    }

    open fun modify(identifier: String, value: ExecutionValue) {
        if (values.containsKey(identifier))
            values[identifier] = value.copyWith(values[identifier]!!.isFinal)
        else if (parent == null)
            throw IllegalStateException("Can't find $identifier to modify.")
        else
            parent.modify(identifier, value)
    }
}