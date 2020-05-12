package dev.abla.frontend

import dev.abla.language.nodes.CompilerExec
import dev.abla.language.nodes.Expression
import dev.abla.language.nodes.Literal
import dev.abla.utils.BackingField

var CompilerExec.compiled: Boolean by BackingField { false }
fun Expression?.isLiteralOrCompileTime(): Boolean =
    this != null && (this is Literal || this is CompilerExec)
