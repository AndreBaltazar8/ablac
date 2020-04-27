package dev.abla.frontend

import dev.abla.language.nodes.CompilerExec
import dev.abla.utils.BackingField

var CompilerExec.compiled: Boolean by BackingField { false }
