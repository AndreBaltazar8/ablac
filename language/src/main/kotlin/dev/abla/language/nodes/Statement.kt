package dev.abla.language.nodes

interface Statement : Declaration {
    override fun deepCopy(): Statement
}