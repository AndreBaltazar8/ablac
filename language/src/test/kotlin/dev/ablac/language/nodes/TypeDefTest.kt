package dev.ablac.language.nodes

import dev.ablac.language.positionZero
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class TypeDefTest {
    @Test
    fun testToHuman() {
        val type = TypeDef("List", arrayOf(
            TypeDefParam(
                TypeDef("T", arrayOf(), positionZero),
                Type("Int", arrayOf(), positionZero)
            )
        ), positionZero)
        assertEquals("List<T : Int>", type.toHuman())
    }
}