package dev.abla.utils

fun printFlushed(message: String) = synchronized(System.out) {
    println(message)
    System.out.flush()
}

suspend fun statementOrder(
    reverse: Boolean,
    first: suspend () -> Unit,
    second: suspend () -> Unit
) {
    if (reverse) {
        second()
        first()
    } else {
        first()
        second()
    }
}