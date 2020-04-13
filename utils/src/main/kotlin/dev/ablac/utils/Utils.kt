package dev.ablac.utils

fun printFlushed(message: String) = synchronized(System.out) {
    println(message)
    System.out.flush()
}