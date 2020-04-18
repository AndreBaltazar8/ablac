package dev.ablac.frontend

import dev.ablac.language.nodes.FunctionDeclaration
import dev.ablac.language.nodes.Literal
import dev.ablac.language.nodes.Modifier
import dev.ablac.language.nodes.Parameter
import dev.ablac.language.positionZero

class CompilerFunctionDeclaration(
    name: String,
    parameters: Array<Parameter>,
    modifiers: Array<Modifier>,
    val executionBlock: suspend (ExecutionVisitor, Array<Any>) -> Literal
) : FunctionDeclaration(name, parameters, null, modifiers, positionZero)