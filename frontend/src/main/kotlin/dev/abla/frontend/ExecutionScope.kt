package dev.abla.frontend

import dev.abla.common.SymbolTable
import dev.abla.language.nodes.PropertyDeclaration
import java.lang.IllegalStateException

open class ExecutionScope(val parent: ExecutionScope?, val symbolTable: SymbolTable) {
    private val values = mutableMapOf<String, ExecutionValue>()

    operator fun get(identifier: String) : ExecutionValue? =
        values[identifier] ?: symbolTable.getThis(identifier)?.let {
            ExecutionValue.ConstSymbol(it)
                .copyWith(it.node.let { node -> if (node is PropertyDeclaration) node.isFinal else false })
        } ?: parent?.get(identifier)

    operator fun set(identifier: String, value: ExecutionValue) {
        values[identifier] = value
    }

    open fun modify(identifier: String, value: ExecutionValue) {
        if (values.containsKey(identifier))
            values[identifier] = value.copyWith(values[identifier]!!.isFinal)
        else {
            val symbol = symbolTable.getThis(identifier)
            if (symbol != null) {
                val node = symbol.node
                if (node is PropertyDeclaration) {
                    if (!node.isFinal)
                        values[identifier] = value.copyWith(false)
                    else
                        throw IllegalStateException("Cannot assign value to $identifier");
                } else
                    throw IllegalStateException("Can't modify parameters yet");
            } else if (parent == null)
                throw IllegalStateException("Can't find $identifier to modify.")
            else
                parent.modify(identifier, value)
        }
    }
}