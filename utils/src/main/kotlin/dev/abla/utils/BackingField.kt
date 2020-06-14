package dev.abla.utils

import java.lang.ref.ReferenceQueue
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread
import kotlin.reflect.KProperty

class BackingField<K, V>(val default: () -> V) {
    companion object {
        fun <K, V> nullable() = BackingField<K, V?> { null }

        private val backingFieldsMap = ConcurrentHashMap<ReferenceQueue<*>, BackingField<*, *>>()

        init {
            thread {
                while (true) {
                    for ((queue, backingField) in backingFieldsMap) {
                        val reference = queue.poll() ?: continue
                        backingField.map.remove(reference)
                    }

                    Thread.sleep(10)
                }
            }
        }
    }

    private val referenceQueue = ReferenceQueue<K>()

    private val map = ConcurrentHashMap<IdentityWeakReference<K>, V>()
    operator fun getValue(thisRef: K, property: KProperty<*>): V =
        map[thisRef.identity()] ?: default()

    operator fun setValue(thisRef: K, property: KProperty<*>, value: V) {
        if (value == null)
            map.remove(thisRef.identity())
        else
            map[thisRef.identity()] = value
    }

    init {
        backingFieldsMap[referenceQueue] = this
    }

    private fun K.identity() = IdentityWeakReference(this, referenceQueue)
}