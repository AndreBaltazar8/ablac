package dev.abla.common

import java.util.*

class SymbolTable(
    val parent: SymbolTable? = null
) {
    init {
        parent?.children?.add(this)
    }

    val children: MutableList<SymbolTable> = Collections.synchronizedList(mutableListOf())
    val symbols: MutableList<Symbol<*>> = Collections.synchronizedList(mutableListOf())

    fun getThis(name: String): Symbol<*>? {
        synchronized(symbols) {
            for (sym in symbols) {
                if (sym.name == name)
                    return@getThis sym
            }
        }
        return null
    }

    fun find(name: String): Symbol<*>? {
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
