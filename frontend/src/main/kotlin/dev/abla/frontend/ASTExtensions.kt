package dev.abla.frontend

import dev.abla.language.nodes.Annotation
import dev.abla.language.nodes.CompileExec
import dev.abla.language.nodes.Expression
import dev.abla.language.nodes.Literal
import dev.abla.language.nodes.MemberAccess
import dev.abla.utils.BackingField

var CompileExec.compiled: Boolean by BackingField { false }
fun Expression?.isLiteralOrCompileTime(): Boolean =
    this != null && (this is Literal || this is CompileExec)
var MemberAccess.returnClassInstance: Boolean by BackingField { false }
var Annotation.value: ExecutionValue.Instance? by BackingField.nullable()

