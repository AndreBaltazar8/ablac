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

    fun findFunction(where: (Symbol.Function) -> Boolean): Symbol.Function? {
        synchronized(symbols) {
            val value = symbols.firstOrNull { it is Symbol.Function && where(it) }
            if (value != null)
                return@findFunction value as Symbol.Function
        }

        if (parent != null)
            return parent.findFunction(where)
        return null
    }
}
