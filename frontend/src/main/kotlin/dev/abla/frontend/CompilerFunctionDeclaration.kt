package dev.abla.frontend

import dev.abla.language.nodes.*
import dev.abla.language.positionZero

class CompilerFunctionDeclaration(
    name: String,
    parameters: MutableList<AssignableParameter>,
    modifiers: MutableList<Modifier>,
    typeParameters: MutableList<TypeDefParam>,
    val executionBlock: suspend (ExecutionVisitor, Array<Any>, Array<Type>) -> ExecutionValue?
) : FunctionDeclaration(
    name,
    parameters,
    null,
    null,
    modifiers,
    mutableListOf(),
    null,
    typeParameters,
    positionZero
)