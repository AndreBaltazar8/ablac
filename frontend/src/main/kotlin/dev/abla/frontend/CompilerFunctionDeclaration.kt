package dev.abla.frontend

import dev.abla.language.nodes.FunctionDeclaration
import dev.abla.language.nodes.Modifier
import dev.abla.language.nodes.Parameter
import dev.abla.language.positionZero

class CompilerFunctionDeclaration(
    name: String,
    parameters: Array<Parameter>,
    modifiers: Array<Modifier>,
    val executionBlock: suspend (ExecutionVisitor, Array<Any>) -> ExecutionValue
) : FunctionDeclaration(name, parameters, null, null, modifiers,  mutableListOf(), positionZero)