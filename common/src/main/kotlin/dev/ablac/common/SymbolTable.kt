package dev.ablac.common

import java.util.*

class SymbolTable(
    val parent: SymbolTable? = null
) {
    init {
        parent?.let { it.children.add(this) }
    }

    val children: MutableList<SymbolTable> = Collections.synchronizedList(mutableListOf<SymbolTable>())
    val symbols: MutableList<Symbol> = Collections.synchronizedList(mutableListOf<Symbol>())

    fun find(name: String): Symbol? {
        synchronized(symbols) {
            for (sym in symbols) {
                if (sym.name == name)
                    return@find sym
            }
        }

        if (parent != null)
            return parent.find(name)
        return null
    }
}
