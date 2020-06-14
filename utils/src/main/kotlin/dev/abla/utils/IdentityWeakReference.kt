package dev.abla.utils

import java.lang.ref.ReferenceQueue
import java.lang.ref.WeakReference

class IdentityWeakReference<T>(
    value: T,
    referenceQueue: ReferenceQueue<T>
) : WeakReference<T>(value, referenceQueue) {
    val hash: Int = System.identityHashCode(value)
    override fun hashCode(): Int = hash
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as IdentityWeakReference<*>

        if (hash != other.hash) return false
        if (get() != other.get()) return false

        return true
    }
}