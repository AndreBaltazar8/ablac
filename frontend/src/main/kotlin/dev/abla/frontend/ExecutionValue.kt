package dev.abla.frontend

import dev.abla.common.Symbol
import dev.abla.language.nodes.Literal
import dev.abla.language.nodes.Type

abstract class ExecutionValue {
    abstract fun copyWith(final: Boolean): ExecutionValue

    data class Value(override val value: Literal) : ExecutionValue() {
        override fun copyWith(final: Boolean): ExecutionValue = Value(value).apply { isFinal = final }
    }

    data class Instance(val type: Type) : ExecutionValue() {
        override val value: Literal
            get() = throw IllegalStateException("Value cannot be converted to literal")

        override fun copyWith(final: Boolean): ExecutionValue = Instance(type).apply { isFinal = final }
    }


    data class ConstSymbol(val symbol: Symbol<*>) : ExecutionValue() {
        override val value: Literal
            get() = throw IllegalStateException("Value cannot be converted to literal")

        override fun copyWith(final: Boolean): ExecutionValue = ConstSymbol(symbol).apply { isFinal = final }
    }
    data class AssignableValue(val assign: (ExecutionValue) -> Unit) : ExecutionValue() {
        override val value: Literal
            get() = throw IllegalStateException("Value cannot be converted to literal")

        override fun copyWith(final: Boolean): ExecutionValue = AssignableValue(assign).apply { isFinal = final }
    }

    abstract val value: Literal
    var isFinal: Boolean = true
}