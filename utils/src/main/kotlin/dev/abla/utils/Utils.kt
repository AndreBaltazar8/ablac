package dev.abla.utils

fun printFlushed(message: String) = synchronized(System.out) {
    println(message)
    System.out.flush()
}

