package dev.ablac.language.nodes

import dev.ablac.language.Identifier
import dev.ablac.language.Position

data class Argument(val name: Identifier?, val value: Expression, val position: Position)