package dev.ablac.utils

import java.util.*
import kotlin.reflect.KProperty

fun printFlushed(message: String) = synchronized(System.out) {
    println(message)
    System.out.flush()
}

class BackingField<K, V>(val default: () -> V) {
    companion object {
        fun <K, V> nullable() = BackingField<K, V?> { null }
    }
    private val map = WeakHashMap<K, V>()
    operator fun getValue(thisRef: K, property: KProperty<*>): V =
        map[thisRef] ?: default()

    operator fun setValue(thisRef: K, property: KProperty<*>, value: V) {
        map[thisRef] = value
    }
}
