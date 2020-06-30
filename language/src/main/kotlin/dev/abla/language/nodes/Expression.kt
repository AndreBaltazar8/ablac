package dev.abla.language.nodes

interface Expression : Statement {
    override fun deepCopy(): Expression
}