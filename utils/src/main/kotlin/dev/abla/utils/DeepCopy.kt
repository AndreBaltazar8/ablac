package dev.abla.utils

interface DeepCopy<T> {
    fun deepCopy(): T
}

/*fun <T : DeepCopy<T>> MutableList<T>.deepCopy(): MutableList<T> = map {
    it.deepCopy()
}.toMutableList()*/

inline fun <reified G, reified T : DeepCopy<T>> MutableList<G>.deepCopy(): MutableList<G> where G : T = map {
    it.deepCopy() as G
}.toMutableList()

inline fun <reified G, reified T : DeepCopy<T>> Array<G>.deepCopy(): Array<G> where G : T = map {
    it.deepCopy() as G
}.toTypedArray()