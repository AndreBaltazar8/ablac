package dev.abla.language

data class Position(val start: Point, val end: Point)
data class Point(val line: Int, val column: Int)

val positionZero = Position(Point(0, 0), Point(0, 0))
