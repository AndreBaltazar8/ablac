package dev.abla.common

import dev.abla.language.nodes.FunctionDeclaration
import dev.abla.language.nodes.Node

sealed class Symbol<T : Node>(open val name: String, open val node: T) {
    data class Function(
        override val name: String,
        override val node: FunctionDeclaration
    ) : Symbol<FunctionDeclaration>(name, node) {
        init {
            node.symbol = this
        }
    }

    data class Variable(
        override val name: String,
        override val node: Node
    ) : Symbol<Node>(name, node) {
        init {
            node.symbol = this
        }
    }
}