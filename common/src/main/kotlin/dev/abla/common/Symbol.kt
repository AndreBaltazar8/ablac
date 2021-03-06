package dev.abla.common

import dev.abla.language.nodes.ClassDeclaration
import dev.abla.language.nodes.FunctionDeclaration
import dev.abla.language.nodes.Node

sealed class Symbol<T : Node>(open val name: String, open val node: T) {
    data class Function(
        override var name: String,
        override val node: FunctionDeclaration
    ) : Symbol<FunctionDeclaration>(name, node) {
        var receiver: Lazy<Class>? = null

        init {
            node.symbol = this
        }
    }

    data class Variable(
        override val name: String,
        override val node: Node
    ) : Symbol<Node>(name, node) {
        var classSymbol: Class? = null

        init {
            node.symbol = this
        }
    }

    data class Class(
        override val name: String,
        override val node: ClassDeclaration
    ) : Symbol<Node>(name, node) {
        val fields = mutableListOf<Variable>()
        val methods = mutableListOf<Function>()

        init {
            node.symbol = this
        }
    }
}