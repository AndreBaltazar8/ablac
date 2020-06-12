package dev.abla.language.nodes

import dev.abla.language.Identifier
import dev.abla.language.Position

data class Argument(var name: Identifier?, var value: Expression, val position: Position)