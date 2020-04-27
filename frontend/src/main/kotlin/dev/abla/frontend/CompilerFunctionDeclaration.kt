package dev.abla.frontend

import dev.abla.language.nodes.FunctionDeclaration
import dev.abla.language.nodes.Literal
import dev.abla.language.nodes.Modifier
import dev.abla.language.nodes.Parameter
import dev.abla.language.positionZero

class CompilerFunctionDeclaration(
    name: String,
    parameters: Array<Parameter>,
    modifiers: Array<Modifier>,
    val executionBlock: suspend (ExecutionVisitor, Array<Any>) -> Literal
) : FunctionDeclaration(name, parameters, null, modifiers, positionZero)