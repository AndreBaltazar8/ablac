package dev.ablac.utils

import kotlinx.coroutines.sync.Mutex
import java.util.*
import java.util.concurrent.locks.Lock
import java.util.concurrent.locks.ReentrantLock


data class NamedLock(internal var lock: ReferenceLock, var locked: Boolean = false) {
    suspend fun lock() {
        lock.lock()

        synchronized(this) {
            if (!locked) {
                locked = true
            }
        }
    }

    fun unlock() = synchronized(this) {
        if (locked) {
            locked = false
            lock.unlock()
        }
    }
}

data class ReferenceLock(internal var references: Int, internal var mutex: Mutex) {
    suspend fun lock() = mutex.lock()
    fun unlock() = mutex.unlock()
}

interface ILockService {
    suspend fun <T> namedLock(name: String, block: suspend (NamedLock) -> T)
}

class LockService : ILockService {
    private val locks = Collections.synchronizedMap(mutableMapOf<String, ReferenceLock>())

    override suspend fun <T> namedLock(name: String, block: suspend (NamedLock) -> T) {
        val lock: ReferenceLock = synchronized(locks) {
            var lock = locks[name]
            if (lock == null) {
                lock = ReferenceLock(0, Mutex())
                locks[name] = lock
            }
            lock.references++
            lock
        }

        val namedLock = NamedLock(lock)
        block(namedLock)
        namedLock.unlock()

        synchronized(locks) {
            lock.references--
            if (lock.references == 0)
                locks.remove(name)
        }
    }
}