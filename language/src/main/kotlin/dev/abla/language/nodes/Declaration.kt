package dev.abla.language.nodes

interface Declaration : Node {
    override fun deepCopy(): Declaration
}