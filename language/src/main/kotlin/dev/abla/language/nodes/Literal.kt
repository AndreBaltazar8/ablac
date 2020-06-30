package dev.abla.language.nodes

interface Literal : Expression {
    override fun deepCopy(): Literal
}