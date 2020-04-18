package dev.ablac.common

import dev.ablac.language.nodes.FunctionDeclaration
import dev.ablac.language.nodes.Node

sealed class Symbol<T : Node>(open val name: String, open val node: T) {
    data class Function(
        override val name: String,
        override val node: FunctionDeclaration
    ) : Symbol<FunctionDeclaration>(name, node)

    data class Variable(
        override val name: String,
        override val node: Node
    ) : Symbol<Node>(name, node)
}