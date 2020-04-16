package dev.ablac.common

import dev.ablac.language.nodes.FunctionDeclaration
import dev.ablac.language.nodes.Node

sealed class Symbol(open val name: String) {
    data class Function(
        override val name: String,
        val functionDeclaration: FunctionDeclaration
    ) : Symbol(name)

    data class Variable(
        override val name: String,
        val node: Node
    ) : Symbol(name)
}