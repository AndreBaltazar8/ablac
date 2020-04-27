package dev.abla.language.nodes

import dev.abla.language.Identifier
import dev.abla.language.Position

data class Argument(val name: Identifier?, val value: Expression, val position: Position)